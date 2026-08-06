import XCTest
@testable import Trans

final class TranslationServiceTests: XCTestCase {
    private struct FailingService: TranslationService {
        func translate(
            text: String,
            targetLanguage: String,
            configuration: TranslationConfiguration
        ) async throws -> TranslationResult {
            throw TranslationError.invalidResponse
        }
    }

    private struct SuccessfulService: TranslationService {
        let provider: TranslationProvider

        func translate(
            text: String,
            targetLanguage: String,
            configuration: TranslationConfiguration
        ) async throws -> TranslationResult {
            TranslationResult(
                text: "translated",
                detectedLanguage: nil,
                targetLanguage: targetLanguage,
                provider: provider
            )
        }
    }

    func testAlibabaRequestUsesAutoSourceAndSignedEcommerceEndpoint() throws {
        let request = try AlibabaTranslationService.makeRequest(
            text: "大疆无人机",
            targetLanguage: TranslationLanguage.english.code,
            accessKeyID: "test-id",
            accessKeySecret: "test-secret",
            date: Date(timeIntervalSince1970: 0),
            nonce: "fixed-nonce"
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://mt.cn-hangzhou.aliyuncs.com/api/translate/web/ecommerce"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-MD5"),
            "8xku/BxY9JOXtnpnno3gnw=="
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Date"),
            "Thu, 01 Jan 1970 00:00:00 GMT"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "acs test-id:hLshyt+csFyzOtlK43YotYWb66w="
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(json["FormatType"], "text")
        XCTAssertEqual(json["SourceLanguage"], "auto")
        XCTAssertEqual(json["TargetLanguage"], "en")
        XCTAssertEqual(json["SourceText"], "大疆无人机")
        XCTAssertEqual(json["Scene"], "title")
    }

    func testAlibabaMapsSimplifiedChineseLanguageCode() {
        XCTAssertEqual(
            AlibabaTranslationService.apiLanguageCode(
                for: TranslationLanguage.chinese.code
            ),
            "zh"
        )
    }

    func testAlibabaRequestUsesConfiguredEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/custom/translate"))
        let request = try AlibabaTranslationService.makeRequest(
            text: "hello",
            targetLanguage: TranslationLanguage.chinese.code,
            accessKeyID: "test-id",
            accessKeySecret: "test-secret",
            endpoint: endpoint
        )

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "example.com")
    }

    func testAlibabaParsesDetectedLanguage() throws {
        let data = Data(
            """
            {
              "Code": 200,
              "Message": "success",
              "Data": {
                "Translated": "DJI Drone",
                "DetectedLanguage": "zh"
              }
            }
            """.utf8
        )

        let result = try AlibabaTranslationService.translationResult(
            from: data,
            targetLanguage: TranslationLanguage.english.code
        )
        XCTAssertEqual(result.text, "DJI Drone")
        XCTAssertEqual(result.detectedLanguage, "zh")
        XCTAssertEqual(result.provider, .alibaba)
    }

    func testCompletionsURLAppendsEndpointToVersionedBaseURL() {
        let result = LLMTranslationService.completionsURL(from: "https://example.com/v1")
        XCTAssertEqual(result?.absoluteString, "https://example.com/v1/chat/completions")
    }

    func testCompletionsURLKeepsCompleteEndpoint() {
        let result = LLMTranslationService.completionsURL(
            from: "https://example.com/openai/v1/chat/completions"
        )
        XCTAssertEqual(result?.absoluteString, "https://example.com/openai/v1/chat/completions")
    }

    func testCompletionsURLRejectsRelativeURL() {
        XCTAssertNil(LLMTranslationService.completionsURL(from: "example.com/v1"))
    }

    func testSharedPromptExplicitlyNamesAdditionalTargetLanguage() {
        XCTAssertEqual(
            LLMTranslationPrompt.userPrompt(
                text: "今天天气怎么样 用这段测试",
                targetLanguage: "ja"
            ),
            "将以下内容翻译成日语\n\n今天天气怎么样 用这段测试"
        )
    }

    func testServicePreferencesNormalizeDuplicatesAndMissingServices() {
        let preferences = TranslationServicePreference.normalized([
            .init(
                id: .llm,
                isEnabled: false,
                customName: " DeepSeek ",
                tag: " 主力服务 "
            ),
            .init(id: .llm, isEnabled: true),
            .init(id: .microsoftPublic, isEnabled: true)
        ])

        XCTAssertEqual(
            preferences.map(\.id),
            [.llm, .microsoftPublic, .microsoftSubscription, .alibaba, .ollama]
        )
        XCTAssertFalse(preferences[0].isEnabled)
        XCTAssertEqual(preferences[0].displayName, "DeepSeek")
        XCTAssertEqual(preferences[0].displayTag, "主力服务")
    }

    func testLegacyServicePreferenceDecodesWithoutNameOrTag() throws {
        let data = Data(#"{"id":"ollama","isEnabled":true}"#.utf8)
        let preference = try JSONDecoder().decode(
            TranslationServicePreference.self,
            from: data
        )

        XCTAssertEqual(preference.displayName, "Ollama")
        XCTAssertNil(preference.displayTag)
    }

    func testOllamaRequestUsesChatEndpointAndSharedPrompt() throws {
        let request = try OllamaTranslationService.makeRequest(
            text: "今天天气真好。",
            targetLanguage: TranslationLanguage.english.code,
            baseURL: TranslationDefaults.ollamaBaseURL,
            model: TranslationDefaults.ollamaModel
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "http://10.162.9.12:11434/api/chat"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 60)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "hy-mt2-1.8b")
        XCTAssertEqual(json["stream"] as? Bool, false)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], LLMTranslationPrompt.systemPrompt)
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertEqual(
            messages[1]["content"],
            LLMTranslationPrompt.userPrompt(
                text: "今天天气真好。",
                targetLanguage: TranslationLanguage.english.code
            )
        )
    }

    func testOllamaParsesChatResponse() throws {
        let data = Data(
            """
            {
              "model": "hy-mt2-1.8b",
              "message": {
                "role": "assistant",
                "content": "The weather is really nice today."
              },
              "done": true
            }
            """.utf8
        )

        let result = try OllamaTranslationService.translationResult(
            from: data,
            targetLanguage: TranslationLanguage.english.code
        )
        XCTAssertEqual(result.text, "The weather is really nice today.")
        XCTAssertEqual(result.targetLanguage, TranslationLanguage.english.code)
        XCTAssertEqual(result.provider, .ollama)
    }

    func testOllamaChatURLReplacesLegacyGenerateEndpoint() {
        let result = OllamaTranslationService.chatURL(
            from: "http://10.162.9.12:11434/api/generate"
        )
        XCTAssertEqual(result?.absoluteString, "http://10.162.9.12:11434/api/chat")
    }

    func testCoordinatorFallsBackInConfiguredOrder() async throws {
        let coordinator = TranslationCoordinator(
            microsoftPublic: FailingService(),
            llm: SuccessfulService(provider: .llm)
        )
        let configuration = makeConfiguration(
            serviceOrder: [.microsoftPublic, .llm]
        )

        let result = try await coordinator.translate(
            text: "hello",
            targetLanguage: TranslationLanguage.chinese.code,
            configuration: configuration
        )

        XCTAssertEqual(result.text, "translated")
        XCTAssertEqual(result.provider, .llm)
    }

    private func makeConfiguration(
        serviceOrder: [TranslationServiceID]
    ) -> TranslationConfiguration {
        TranslationConfiguration(
            serviceOrder: serviceOrder,
            microsoftPublicEndpoint: TranslationDefaults.microsoftPublicEndpoint,
            microsoftSubscriptionEndpoint: TranslationDefaults.microsoftSubscriptionEndpoint,
            microsoftKey: "",
            microsoftRegion: "",
            alibabaEndpoint: TranslationDefaults.alibabaEndpoint,
            alibabaAccessKeyID: "",
            alibabaAccessKeySecret: "",
            llmBaseURL: TranslationDefaults.llmBaseURL,
            llmAPIKey: "",
            llmModel: TranslationDefaults.llmModel,
            ollamaBaseURL: TranslationDefaults.ollamaBaseURL,
            ollamaModel: TranslationDefaults.ollamaModel
        )
    }
}
