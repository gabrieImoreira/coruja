import XCTest
@testable import coruja

final class SummaryEngineTests: XCTestCase {
    private func openAIResponse(content: String) -> Data {
        let payload: [String: Any] = [
            "choices": [["message": ["content": content]]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testMissingAPIKeyThrows() async {
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "oi", startMs: 0)]
        do {
            _ = try await SummaryEngine.summarize(
                segments: segments, apiKey: "", model: "gpt-4o-mini", summaryType: .topicos
            )
            XCTFail("expected missingAPIKey")
        } catch SummaryEngine.SummaryError.missingAPIKey {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEmptyTranscriptThrows() async {
        do {
            _ = try await SummaryEngine.summarize(
                segments: [], apiKey: "sk-test", model: "gpt-4o-mini", summaryType: .topicos
            )
            XCTFail("expected emptyTranscript")
        } catch SummaryEngine.SummaryError.emptyTranscript {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSingleChunkReturnsChunkSummaryDirectly() async throws {
        let content = "{\"resumo\": \"## Tópicos\\n\\n### Pagamentos\\ndiscutido X\", \"itens_de_acao\": []}"
        MockURLProtocol.handler = { [weak self] _ in (200, self!.openAIResponse(content: content)) }
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "falamos de pagamentos", startMs: 0)]

        let summary = try await SummaryEngine.summarize(
            segments: segments, apiKey: "sk-test", model: "gpt-4o-mini",
            summaryType: .topicos, session: .mocked()
        )

        XCTAssertTrue(summary.resumo.contains("Pagamentos"))
        XCTAssertTrue(summary.itensDeAcao.isEmpty)
    }

    func testActionItemsAreCollectedAcrossChunks() async throws {
        let content = "{\"resumo\": \"## Pauta\\n- x\", \"itens_de_acao\": [{\"item\": \"mandar email\", \"responsavel\": \"Ana\", \"prazo\": null}]}"
        MockURLProtocol.handler = { [weak self] _ in (200, self!.openAIResponse(content: content)) }
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "eu mando o email", startMs: 0)]

        let summary = try await SummaryEngine.summarize(
            segments: segments, apiKey: "sk-test", model: "gpt-4o-mini",
            summaryType: .ata, session: .mocked()
        )

        XCTAssertEqual(summary.itensDeAcao.count, 1)
        XCTAssertEqual(summary.itensDeAcao[0].responsavel, "Ana")
    }

    func testHTTPErrorIsSurfaced() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let segments = [SummaryEngine.TimedSegment(speaker: "me", text: "oi", startMs: 0)]
        do {
            _ = try await SummaryEngine.summarize(
                segments: segments, apiKey: "sk-bad", model: "gpt-4o-mini",
                summaryType: .topicos, session: .mocked()
            )
            XCTFail("expected httpError")
        } catch SummaryEngine.SummaryError.httpError(let code) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
