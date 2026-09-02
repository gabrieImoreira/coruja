import AppKit
import Foundation

/// Downloads a new release's zip, unpacks it, and replaces the running
/// /Applications/Coruja.app, then relaunches the new copy and terminates
/// this process. Every step before "replace" must succeed — the currently
/// running app is only ever touched (moved to the Trash, not deleted) after
/// the new bundle is downloaded, unzipped, and validated.
enum UpdateInstaller {
    enum InstallError: Error, CustomStringConvertible {
        case downloadFailed
        case unzipFailed
        case invalidBundle
        case installFailed(String)

        var description: String {
            switch self {
            case .downloadFailed: return "não foi possível baixar a atualização"
            case .unzipFailed: return "não foi possível descompactar a atualização"
            case .invalidBundle: return "o pacote baixado não parece um app válido"
            case .installFailed(let reason): return "não foi possível instalar a atualização (\(reason))"
            }
        }
    }

    @MainActor
    static func install(_ info: UpdateInfo, session: URLSession = .shared) async throws {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("coruja", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let zipPath = cacheDir.appendingPathComponent("update.zip")
        try? FileManager.default.removeItem(at: zipPath)

        guard
            let (downloaded, response) = try? await session.download(from: info.zipURL),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { throw InstallError.downloadFailed }
        try FileManager.default.moveItem(at: downloaded, to: zipPath)

        let extractDir = cacheDir.appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path], error: .unzipFailed)

        guard
            let contents = try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil),
            let appDir = contents.first(where: { $0.pathExtension == "app" }),
            FileManager.default.fileExists(atPath: appDir.appendingPathComponent("Contents/Info.plist").path)
        else { throw InstallError.invalidBundle }

        // Removes the quarantine flag Gatekeeper would otherwise attach to
        // anything downloaded — this is the manual `xattr -cr` step the
        // README asks users to run today, done for them.
        try run("/usr/bin/xattr", ["-cr", appDir.path], error: .installFailed("xattr"))

        let installedURL = URL(fileURLWithPath: "/Applications/Coruja.app")
        var backupURL: URL?
        if FileManager.default.fileExists(atPath: installedURL.path) {
            let backup = cacheDir.appendingPathComponent("Coruja.app.backup")
            try? FileManager.default.removeItem(at: backup) // stale leftover from a prior failed attempt
            try FileManager.default.moveItem(at: installedURL, to: backup)
            backupURL = backup
        }

        do {
            try FileManager.default.moveItem(at: appDir, to: installedURL)
        } catch {
            // The new bundle couldn't be placed — restore the old one so the user
            // is never left with nothing at /Applications/Coruja.app.
            if let backupURL {
                try? FileManager.default.moveItem(at: backupURL, to: installedURL)
            }
            throw error
        }

        // New bundle is in place — the backup (if any) is no longer needed.
        if let backupURL {
            try? FileManager.default.trashItem(at: backupURL, resultingItemURL: nil)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: installedURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private static func run(_ launchPath: String, _ args: [String], error: InstallError) throws {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw error }
    }
}
