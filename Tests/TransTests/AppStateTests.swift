import XCTest
@testable import Trans

private struct ImmediateTranslationService: TranslationService {
    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult {
        TranslationResult(
            text: "你好",
            detectedLanguage: "en",
            targetLanguage: targetLanguage,
            provider: .microsoft
        )
    }
}

private struct DelayedEchoTranslationService: TranslationService {
    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult {
        if text == "first" {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return TranslationResult(
            text: text.uppercased(),
            detectedLanguage: "en",
            targetLanguage: targetLanguage,
            provider: .microsoft
        )
    }
}

final class AppStateTests: XCTestCase {
    @MainActor
    func testTranslationOnlyEntersHistoryWhenSubmitted() async throws {
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        let coordinator = TranslationCoordinator(
            microsoftPublic: ImmediateTranslationService()
        )
        let state = AppState(
            settings: settings,
            coordinator: coordinator,
            defaults: defaults
        )

        state.inputText = "hello"
        state.translateNow()
        for _ in 0..<50 where state.translatedText.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(state.translatedText, "你好")
        XCTAssertTrue(state.history.isEmpty)

        state.submitTranslation()

        XCTAssertEqual(state.history.count, 1)
        XCTAssertEqual(state.history.first?.sourceText, "hello")
        XCTAssertTrue(state.inputText.isEmpty)
        XCTAssertEqual(state.inputReplacementID, 1)
    }

    @MainActor
    func testNewInputCancelsPreviousRequestWithoutReplacingEditorText() async throws {
        let suiteName = "AppStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            settings: SettingsStore(defaults: defaults),
            coordinator: TranslationCoordinator(
                microsoftPublic: DelayedEchoTranslationService()
            ),
            defaults: defaults
        )

        state.inputText = "first"
        state.translateNow()
        try await Task.sleep(nanoseconds: 30_000_000)
        state.inputText = "second"
        state.translateNow()
        for _ in 0..<50 where state.translatedText != "SECOND" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(state.inputText, "second")
        XCTAssertEqual(state.translatedText, "SECOND")
        XCTAssertEqual(state.inputReplacementID, 0)
        XCTAssertTrue(state.history.isEmpty)
    }
}
