import XCTest
@testable import coruja

final class TitleEngineTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func openAIResponse(content: String) -> Data {
        let payload: [String: Any] = ["choices": [["message": ["content": content]]]]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testMissingAPIKeyThrows() async {
        do {
            _ = try await TitleEngine.generate(
                segments: [(speaker: "me", text: "falamos de pagamentos e reembolso")],
                root: FileManager.default.temporaryDirectory,
                excluding: FileManager.default.temporaryDirectory,
                apiKey: "", model: "gpt-4o-mini"
            )
            XCTFail("expected missingAPIKey")
        } catch TitleEngine.TitleError.missingAPIKey {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStripsQuotesAndExtraLines() async throws {
        MockURLProtocol.handler = { [weak self] _ in
            (200, self!.openAIResponse(content: "\"Reembolso de sinistro\"\nnota extra"))
        }
        let title = try await TitleEngine.generate(
            segments: [(speaker: "me", text: "vamos falar do reembolso do sinistro hoje")],
            root: FileManager.default.temporaryDirectory,
            excluding: FileManager.default.temporaryDirectory,
            apiKey: "sk-test", model: "gpt-4o-mini", session: .mocked()
        )
        XCTAssertEqual(title, "Reembolso de sinistro")
    }
}
