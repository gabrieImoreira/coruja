import AppKit
import Foundation

/// Downloads a new release's zip, unpacks it, and replaces the running
/// .app bundle, then relaunches the new copy and terminates this process.
/// Every step before "replace" must succeed. The currently installed app is
/// never deleted up front: it's renamed aside to a backup location in this
/// app's own cache directory first, the new bundle is moved into place, and
/// only once that succeeds is the backup sent to the Trash. If placing the
/// new bundle fails, the backup is moved back so the user is never left
/// without a working app.
enum UpdateInstaller {
    enum InstallError: Error, CustomStringConvertible {
        case downloadFailed
        case unzipFailed
        case invalidBundle
        case installFailed(String)
        case notAppBundle

        var description: String {
            switch self {
            case .downloadFailed: return "não foi possível baixar a atualização"
            case .unzipFailed: return "não foi possível descompactar a atualização"
            case .invalidBundle: return "o pacote baixado não parece um app válido"
            case .installFailed(let reason): return "não foi possível instalar a atualização (\(reason))"
            case .notAppBundle: return "atualização automática só funciona quando a coruja roda como um .app instalado"
            }
        }
    }

    @MainActor
    static func install(_ info: UpdateInfo, session: URLSession = .shared) async throws {
        let installedURL = try await performInstall(info, session: session)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: installedURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Everything up to (but not including) the relaunch/terminate tail:
    /// download, unzip, validate, and swap the bundle. None of this touches
    /// AppKit, so it doesn't need main-actor isolation — keeping it off the
    /// main actor means this synchronous disk/process I/O (which can run
    /// over a bundle hundreds of MB in size, including the bundled whisper
    /// model) never blocks the UI. Returns the URL the new bundle now lives
    /// at, on success.
    private static func performInstall(_ info: UpdateInfo, session: URLSession) async throws -> URL {
        // A raw CLI/LaunchAgent install has no real .app bundle to replace —
        // refuse cleanly instead of writing to a path we don't own (mirrors
        // Notify.swift's isRunningAsAppBundle check).
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw InstallError.notAppBundle
        }
        let installedURL = Bundle.main.bundleURL

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
            // is never left with nothing at the installed app's path.
            if let backupURL {
                try? FileManager.default.moveItem(at: backupURL, to: installedURL)
            }
            throw error
        }

        // New bundle is in place — the backup (if any) is no longer needed.
        if let backupURL {
            try? FileManager.default.trashItem(at: backupURL, resultingItemURL: nil)
        }

        return installedURL
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
