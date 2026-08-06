import Foundation
import CryptoKit

enum TranslationError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case httpStatus(Int, String)
    case emptyResult
    case missingMicrosoftSubscriptionConfiguration
    case missingAlibabaConfiguration
    case missingLLMConfiguration
    case missingOllamaConfiguration
    case allProvidersFailed

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "服务地址无效"
        case .invalidResponse:
            return "翻译服务返回了无效响应"
        case let .httpStatus(status, message):
            return message.isEmpty ? "翻译服务错误（\(status)）" : message
        case .emptyResult:
            return "翻译结果为空"
        case .missingMicrosoftSubscriptionConfiguration:
            return "请先完成微软订阅配置"
        case .missingAlibabaConfiguration:
            return "请先完成阿里翻译配置"
        case .missingLLMConfiguration:
            return "请先完成 LLM 配置"
        case .missingOllamaConfiguration:
            return "请先完成 Ollama 配置"
        case .allProvidersFailed:
            return "翻译暂时不可用，请检查网络或服务配置"
        }
    }
}

protocol TranslationService {
    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult
}

struct MicrosoftTranslationService: TranslationService {
    enum Access {
        case publicEndpoint
        case subscription
    }

    let access: Access

    private struct RequestBody: Encodable {
        let text: String

        enum CodingKeys: String, CodingKey {
            case text = "Text"
        }
    }

    private struct ResponseBody: Decodable {
        struct DetectedLanguage: Decodable {
            let language: String
        }

        struct Translation: Decodable {
            let text: String
            let to: String
        }

        let detectedLanguage: DetectedLanguage?
        let translations: [Translation]
    }

    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult {
        if access == .subscription,
           !configuration.hasMicrosoftSubscriptionConfiguration {
            throw TranslationError.missingMicrosoftSubscriptionConfiguration
        }
        let baseURL = access == .subscription
            ? configuration.microsoftSubscriptionEndpoint
            : configuration.microsoftPublicEndpoint

        guard var components = serviceURLComponents(from: baseURL) else {
            throw TranslationError.invalidEndpoint
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "api-version" || $0.name == "to" }
        queryItems.append(contentsOf: [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "to", value: targetLanguage)
        ])
        components.queryItems = queryItems
        guard let url = components.url else {
            throw TranslationError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Trans/1.0", forHTTPHeaderField: "User-Agent")
        if access == .subscription {
            request.setValue(configuration.microsoftKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            let region = configuration.microsoftRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !region.isEmpty {
                request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
            }
        }
        request.httpBody = try JSONEncoder().encode([RequestBody(text: text)])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let payload = try? JSONDecoder().decode([ResponseBody].self, from: data),
              let first = payload.first,
              let translation = first.translations.first else {
            throw TranslationError.invalidResponse
        }
        let translated = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            throw TranslationError.emptyResult
        }
        return TranslationResult(
            text: translated,
            detectedLanguage: first.detectedLanguage?.language,
            targetLanguage: translation.to,
            provider: .microsoft
        )
    }
}

struct AlibabaTranslationService: TranslationService {
    static let defaultEndpoint = URL(string: TranslationDefaults.alibabaEndpoint)!
    private static let accept = "application/json"
    private static let contentType = "application/json;charset=utf-8"
    private static let signatureMethod = "HMAC-SHA1"
    private static let apiVersion = "2019-01-02"

    private struct RequestBody: Encodable {
        let formatType = "text"
        let sourceLanguage = "auto"
        let targetLanguage: String
        let sourceText: String
        let scene = "title"

        enum CodingKeys: String, CodingKey {
            case formatType = "FormatType"
            case sourceLanguage = "SourceLanguage"
            case targetLanguage = "TargetLanguage"
            case sourceText = "SourceText"
            case scene = "Scene"
        }
    }

    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult {
        guard configuration.hasAlibabaConfiguration else {
            throw TranslationError.missingAlibabaConfiguration
        }
        guard let endpoint = serviceURLComponents(from: configuration.alibabaEndpoint)?.url else {
            throw TranslationError.invalidEndpoint
        }

        let request = try Self.makeRequest(
            text: text,
            targetLanguage: targetLanguage,
            accessKeyID: configuration.alibabaAccessKeyID,
            accessKeySecret: configuration.alibabaAccessKeySecret,
            endpoint: endpoint
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try Self.translationResult(
            from: data,
            targetLanguage: targetLanguage
        )
    }

    static func makeRequest(
        text: String,
        targetLanguage: String,
        accessKeyID: String,
        accessKeySecret: String,
        date: Date = Date(),
        nonce: String = UUID().uuidString,
        endpoint: URL = defaultEndpoint
    ) throws -> URLRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(
            RequestBody(
                targetLanguage: apiLanguageCode(for: targetLanguage),
                sourceText: text
            )
        )
        let contentMD5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        let dateHeader = Self.dateHeader(for: date)
        let path = endpoint.path
        let stringToSign = [
            "POST",
            accept,
            contentMD5,
            contentType,
            dateHeader,
            "x-acs-signature-method:\(signatureMethod)",
            "x-acs-signature-nonce:\(nonce)",
            "x-acs-version:\(apiVersion)"
        ].joined(separator: "\n") + "\n" + path
        let key = SymmetricKey(data: Data(accessKeySecret.utf8))
        let authenticationCode = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: key
        )
        let signature = Data(authenticationCode).base64EncodedString()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(contentMD5, forHTTPHeaderField: "Content-MD5")
        request.setValue(dateHeader, forHTTPHeaderField: "Date")
        request.setValue(endpoint.host, forHTTPHeaderField: "Host")
        request.setValue(
            "acs \(accessKeyID):\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(nonce, forHTTPHeaderField: "x-acs-signature-nonce")
        request.setValue(signatureMethod, forHTTPHeaderField: "x-acs-signature-method")
        request.setValue(apiVersion, forHTTPHeaderField: "x-acs-version")
        request.setValue("Trans/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        return request
    }

    static func apiLanguageCode(for languageCode: String) -> String {
        switch languageCode {
        case TranslationLanguage.chinese.code:
            return "zh"
        default:
            return languageCode
        }
    }

    private static func dateHeader(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func translationResult(
        from data: Data,
        targetLanguage: String
    ) throws -> TranslationResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranslationError.invalidResponse
        }
        let payload = root["TranslateResponse"] as? [String: Any] ?? root
        let code = integerValue(payload["Code"] ?? payload["errorCode"])
        let message = payload["Message"] as? String
            ?? payload["errorMsg"] as? String
            ?? ""
        if let code = code, code != 200 {
            throw TranslationError.httpStatus(code, message)
        }

        let responseData = payload["Data"] as? [String: Any]
        let translated = (responseData?["Translated"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !translated.isEmpty else {
            throw TranslationError.emptyResult
        }
        return TranslationResult(
            text: translated,
            detectedLanguage: responseData?["DetectedLanguage"] as? String,
            targetLanguage: targetLanguage,
            provider: .alibaba
        )
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }
}

enum LLMTranslationPrompt {
    struct Message: Codable, Equatable {
        let role: String
        let content: String
    }

    static let systemPrompt = """
    你是一个翻译专家，直接给我翻译的结果，不要有任何额外的信息。
    规则：在没有明确要求翻译成什么语言的时候遵循：收到英文翻译成中文，收到中文翻译成英文，中英混杂的情况下优先翻译成英文。
    判断输入语言要看整段文本的主体，不要只看开头几个词。中文为主的文本即使开头有英文单词也算中文输入，必须翻译成英文。
    按键名、专有名词、代码如 Shift、Enter、macOS 保留原文不翻译。
    """

    static func messages(text: String, targetLanguage: String) -> [Message] {
        var messages = [Message(role: "system", content: systemPrompt)]
        if let targetPrompt = targetLanguagePrompt(for: targetLanguage) {
            messages.append(Message(role: "user", content: targetPrompt))
        }
        messages.append(Message(role: "user", content: text))
        return messages
    }

    private static func targetLanguagePrompt(for code: String) -> String? {
        guard code != TranslationLanguage.chinese.code,
              code != TranslationLanguage.english.code else {
            return nil
        }
        return "将以下内容翻译成\(promptLanguageName(for: code))"
    }

    private static func promptLanguageName(for code: String) -> String {
        switch code {
        case "zh-Hans", "zh": return "中文"
        case "en": return "英语"
        case "ja": return "日语"
        case "ko": return "韩语"
        case "fr": return "法语"
        case "de": return "德语"
        case "es": return "西班牙语"
        case "it": return "意大利语"
        case "pt": return "葡萄牙语"
        case "ru": return "俄语"
        case "ar": return "阿拉伯语"
        default: return TranslationLanguage.language(for: code).name
        }
    }
}

struct LLMTranslationService: TranslationService {
    private struct RequestBody: Encodable {
        let model: String
        let messages: [LLMTranslationPrompt.Message]
        let temperature: Double
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            let message: LLMTranslationPrompt.Message
        }

        let choices: [Choice]
    }

    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult {
        guard configuration.hasLLMConfiguration else {
            throw TranslationError.missingLLMConfiguration
        }
        let request = try Self.makeRequest(
            text: text,
            targetLanguage: targetLanguage,
            baseURL: configuration.llmBaseURL,
            apiKey: configuration.llmAPIKey,
            model: configuration.llmModel
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let payload = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let first = payload.choices.first else {
            throw TranslationError.invalidResponse
        }
        let translated = first.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            throw TranslationError.emptyResult
        }
        return TranslationResult(
            text: translated,
            detectedLanguage: nil,
            targetLanguage: targetLanguage,
            provider: .llm
        )
    }

    static func makeRequest(
        text: String,
        targetLanguage: String,
        baseURL: String,
        apiKey: String,
        model: String
    ) throws -> URLRequest {
        guard let url = completionsURL(from: baseURL) else {
            throw TranslationError.invalidEndpoint
        }
        let body = RequestBody(
            model: model,
            messages: LLMTranslationPrompt.messages(
                text: text,
                targetLanguage: targetLanguage
            ),
            temperature: 0
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func completionsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https" || components.scheme == "http" else {
            return nil
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("chat/completions") {
            return components.url
        }
        components.path = path.isEmpty ? "/v1/chat/completions" : "/\(path)/chat/completions"
        return components.url
    }
}

struct OllamaTranslationService: TranslationService {
    private struct RequestBody: Encodable {
        let model: String
        let messages: [LLMTranslationPrompt.Message]
        let stream = false
    }

    private struct ResponseBody: Decodable {
        let message: LLMTranslationPrompt.Message
    }

    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult {
        guard configuration.hasOllamaConfiguration else {
            throw TranslationError.missingOllamaConfiguration
        }
        let request = try Self.makeRequest(
            text: text,
            targetLanguage: targetLanguage,
            baseURL: configuration.ollamaBaseURL,
            model: configuration.ollamaModel
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try Self.translationResult(from: data, targetLanguage: targetLanguage)
    }

    static func makeRequest(
        text: String,
        targetLanguage: String,
        baseURL: String,
        model: String
    ) throws -> URLRequest {
        guard let url = chatURL(from: baseURL) else {
            throw TranslationError.invalidEndpoint
        }
        let body = RequestBody(
            model: model,
            messages: LLMTranslationPrompt.messages(
                text: text,
                targetLanguage: targetLanguage
            )
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Trans/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func translationResult(
        from data: Data,
        targetLanguage: String
    ) throws -> TranslationResult {
        guard let payload = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw TranslationError.invalidResponse
        }
        let translated = payload.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else {
            throw TranslationError.emptyResult
        }
        return TranslationResult(
            text: translated,
            detectedLanguage: nil,
            targetLanguage: targetLanguage,
            provider: .ollama
        )
    }

    static func chatURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "https" || components.scheme == "http",
              components.host != nil else {
            return nil
        }
        let path = components.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        if path.hasSuffix("api/chat") {
            return components.url
        }
        if path.hasSuffix("api/generate") {
            components.path = "/\(path.dropLast("generate".count))chat"
            return components.url
        }
        if path == "api" || path.hasSuffix("/api") {
            components.path = "/\(path)/chat"
        } else {
            components.path = path.isEmpty
                ? "/api/chat"
                : "/\(path)/api/chat"
        }
        return components.url
    }
}

actor TranslationCoordinator {
    private let microsoftPublic: any TranslationService
    private let microsoftSubscription: any TranslationService
    private let alibaba: any TranslationService
    private let llm: any TranslationService
    private let ollama: any TranslationService

    init(
        microsoftPublic: any TranslationService = MicrosoftTranslationService(
            access: .publicEndpoint
        ),
        microsoftSubscription: any TranslationService = MicrosoftTranslationService(
            access: .subscription
        ),
        alibaba: any TranslationService = AlibabaTranslationService(),
        llm: any TranslationService = LLMTranslationService(),
        ollama: any TranslationService = OllamaTranslationService()
    ) {
        self.microsoftPublic = microsoftPublic
        self.microsoftSubscription = microsoftSubscription
        self.alibaba = alibaba
        self.llm = llm
        self.ollama = ollama
    }

    func translate(
        text: String,
        targetLanguage: String,
        configuration: TranslationConfiguration
    ) async throws -> TranslationResult {
        for serviceID in configuration.serviceOrder {
            try Task.checkCancellation()
            do {
                return try await service(for: serviceID).translate(
                    text: text,
                    targetLanguage: targetLanguage,
                    configuration: configuration
                )
            } catch {
                try Task.checkCancellation()
            }
        }
        throw TranslationError.allProvidersFailed
    }

    private func service(for id: TranslationServiceID) -> any TranslationService {
        switch id {
        case .microsoftPublic:
            return microsoftPublic
        case .microsoftSubscription:
            return microsoftSubscription
        case .alibaba:
            return alibaba
        case .llm:
            return llm
        case .ollama:
            return ollama
        }
    }
}

private func serviceURLComponents(from value: String) -> URLComponents? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
          components.scheme == "https",
          components.host != nil else {
        return nil
    }
    return components
}

private func validate(response: URLResponse, data: Data) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
        throw TranslationError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
        let message = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { $0 as? [String: Any] }
            .flatMap { dictionary -> String? in
                if let error = dictionary["error"] as? [String: Any] {
                    return error["message"] as? String
                }
                return dictionary["message"] as? String
                    ?? dictionary["Message"] as? String
                    ?? dictionary["errorMsg"] as? String
            } ?? ""
        throw TranslationError.httpStatus(httpResponse.statusCode, message)
    }
}
