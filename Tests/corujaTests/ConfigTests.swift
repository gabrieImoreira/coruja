import XCTest
@testable import coruja

final class ConfigTests: XCTestCase {
    private var tempDir: URL!
    private var originalPath: URL!

    override func setUp() {
        super.setUp()
        originalPath = Config.path
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coruja-config-test-\(UUID().uuidString)", isDirectory: true)
        Config.path = tempDir.appendingPathComponent("config.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        Config.path = originalPath
        super.tearDown()
    }

    func testSummaryTypeDefaultsToTopicos() {
        XCTAssertEqual(Config.summaryType(), "topicos")
    }

    func testLlmModelDefaultsToGpt4oMini() {
        XCTAssertEqual(Config.llmModel(), "gpt-4o-mini")
    }

    func testSaveAndReloadSummaryTypeAndModel() {
        Config.save(
            recordingsDir: "",
            transcriptionEnabled: true,
            transcriptionEngine: "whisper",
            transcriptionLanguage: "pt",
            llmPassEnabled: true,
            llmModel: "gpt-4.1-mini",
            summaryType: "ata",
            micVoiceProcessing: false
        )
        XCTAssertEqual(Config.summaryType(), "ata")
        XCTAssertEqual(Config.llmModel(), "gpt-4.1-mini")
    }

    func testSaveRejectsUnknownSummaryType() {
        Config.save(
            recordingsDir: "",
            transcriptionEnabled: true,
            transcriptionEngine: "whisper",
            transcriptionLanguage: "pt",
            llmPassEnabled: false,
            llmModel: "gpt-4o-mini",
            summaryType: "garbage",
            micVoiceProcessing: false
        )
        XCTAssertEqual(Config.summaryType(), "topicos")
    }
}
