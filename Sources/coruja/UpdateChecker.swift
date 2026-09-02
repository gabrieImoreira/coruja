import Foundation

struct UpdateInfo: Equatable, Sendable {
    let version: String
    let zipURL: URL
    let releaseNotesURL: URL
}

/// Checks GitHub Releases for a newer coruja version than the one running.
/// No auth (public API, 60 req/h per IP — plenty for a check on launch plus
/// once a day) and no external dependency (Foundation's URLSession/JSONDecoder
/// only). See UpdateInstaller for what happens when the user accepts.
enum UpdateChecker {
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/gabrieImoreira/coruja/releases/latest"
    )!
    private static let dismissedVersionKey = "corujaDismissedUpdateVersion"

    /// Returns the latest release's info if it's newer than `currentVersion`,
    /// nil otherwise — including on any network or parse failure. A failed
    /// check is silent for the automatic path; callers that need to
    /// distinguish "up to date" from "check failed" (the manual Settings
    /// button) should treat `nil` as "nothing to report" either way, since
    /// there's no actionable difference for the user.
    static func checkForUpdate(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
        session: URLSession = .shared
    ) async -> UpdateInfo? {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }

        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Release: Decodable { let tag_name: String; let html_url: String; let assets: [Asset] }

        guard
            let release = try? JSONDecoder().decode(Release.self, from: data),
            let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
            let zipURL = URL(string: asset.browser_download_url),
            let notesURL = URL(string: release.html_url)
        else { return nil }

        let remoteVersion = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isNewer(remoteVersion, than: currentVersion) else { return nil }
        return UpdateInfo(version: remoteVersion, zipURL: zipURL, releaseNotesURL: notesURL)
    }

    /// True if `remote` is a strictly greater "major.minor.patch" version
    /// than `current`. Missing or non-numeric components compare as 0 —
    /// good enough for this app's plain semver tags (no pre-release suffixes).
    static func isNewer(_ remote: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let r = parts(remote), c = parts(current)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }

    // MARK: - Dismissal (automatic-check path only — see Settings for the manual check)

    static func isDismissed(_ version: String, defaults: UserDefaults = .standard) -> Bool {
        guard let dismissed = defaults.string(forKey: dismissedVersionKey) else { return false }
        return !isNewer(version, than: dismissed)
    }

    static func dismiss(_ version: String, defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: dismissedVersionKey)
    }
}
