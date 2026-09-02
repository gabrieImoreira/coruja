import XCTest
@testable import coruja

final class UpdateCheckerTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func releasePayload(tag: String) -> Data {
        let payload: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/gabrieImoreira/coruja/releases/tag/\(tag)",
            "assets": [
                ["name": "coruja-\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)-macos.zip",
                 "browser_download_url": "https://example.com/coruja.zip"]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testIsNewerBasicCases() {
        XCTAssertTrue(UpdateChecker.isNewer("0.6.0", than: "0.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.5.0", than: "0.5.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.4.9", than: "0.5.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.5.1", than: "0.5"))
    }

    func testCheckForUpdateReturnsInfoWhenNewer() async {
        MockURLProtocol.handler = { [weak self] _ in (200, self!.releasePayload(tag: "v0.6.0")) }
        let info = await UpdateChecker.checkForUpdate(currentVersion: "0.5.0", session: .mocked())
        XCTAssertEqual(info?.version, "0.6.0")
        XCTAssertEqual(info?.zipURL, URL(string: "https://example.com/coruja.zip"))
    }

    func testCheckForUpdateReturnsNilWhenNotNewer() async {
        MockURLProtocol.handler = { [weak self] _ in (200, self!.releasePayload(tag: "v0.5.0")) }
        let info = await UpdateChecker.checkForUpdate(currentVersion: "0.5.0", session: .mocked())
        XCTAssertNil(info)
    }

    func testCheckForUpdateReturnsNilOnHTTPError() async {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let info = await UpdateChecker.checkForUpdate(currentVersion: "0.5.0", session: .mocked())
        XCTAssertNil(info)
    }

    func testDismissalGate() {
        let defaults = UserDefaults(suiteName: "coruja-update-checker-tests")!
        defaults.removePersistentDomain(forName: "coruja-update-checker-tests")

        XCTAssertFalse(UpdateChecker.isDismissed("0.6.0", defaults: defaults))
        UpdateChecker.dismiss("0.6.0", defaults: defaults)
        XCTAssertTrue(UpdateChecker.isDismissed("0.6.0", defaults: defaults))
        XCTAssertFalse(UpdateChecker.isDismissed("0.7.0", defaults: defaults))

        defaults.removePersistentDomain(forName: "coruja-update-checker-tests")
    }
}
