import Foundation

enum TranslationProvider: String, Codable, CaseIterable, Identifiable {
    case automatic
    case microsoft
    case alibaba
    case llm
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .microsoft: return "微软翻译"
        case .alibaba: return "阿里翻译"
        case .llm: return "LLM"
        case .ollama: return "Ollama"
        }
    }
}

enum TranslationServiceID: String, Codable, CaseIterable, Identifiable, Hashable {
    case microsoftPublic
    case microsoftSubscription
    case alibaba
    case llm
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microsoftPublic: return "微软公共"
        case .microsoftSubscription: return "微软订阅"
        case .alibaba: return "阿里翻译"
        case .llm: return "LLM"
        case .ollama: return "Ollama"
        }
    }
}

struct TranslationServicePreference: Codable, Identifiable, Equatable {
    let id: TranslationServiceID
    var isEnabled: Bool
    var customName: String?
    var tag: String?

    init(
        id: TranslationServiceID,
        isEnabled: Bool,
        customName: String? = nil,
        tag: String? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.customName = customName
        self.tag = tag
    }

    var displayName: String {
        Self.cleaned(customName) ?? id.title
    }

    var displayTag: String? {
        Self.cleaned(tag)
    }

    static let defaultOrder = TranslationServiceID.allCases.map {
        TranslationServicePreference(id: $0, isEnabled: true)
    }

    static func normalized(
        _ preferences: [TranslationServicePreference]
    ) -> [TranslationServicePreference] {
        var seen = Set<TranslationServiceID>()
        var result = preferences.filter { seen.insert($0.id).inserted }
        for id in TranslationServiceID.allCases where !seen.contains(id) {
            result.append(TranslationServicePreference(id: id, isEnabled: true))
        }
        result = result.map { preference in
            var normalized = preference
            normalized.customName = cleaned(preference.customName)
            normalized.tag = cleaned(preference.tag)
            return normalized
        }
        return result
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }
}

enum TranslationDefaults {
    static let microsoftPublicEndpoint =
        "https://api-edge.cognitive.microsofttranslator.com/translate"
    static let microsoftSubscriptionEndpoint =
        "https://api.cognitive.microsofttranslator.com/translate"
    static let alibabaEndpoint =
        "https://mt.cn-hangzhou.aliyuncs.com/api/translate/web/ecommerce"
    static let llmBaseURL = "https://api.openai.com/v1"
    static let llmModel = "gpt-4.1-mini"
    static let ollamaBaseURL = "http://10.162.9.12:11434"
    static let ollamaModel = "hy-mt2-1.8b"
}

struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    static let chinese = TranslationLanguage(code: "zh-Hans", name: "中文")
    static let english = TranslationLanguage(code: "en", name: "English")

    static let additional: [TranslationLanguage] = [
        .init(code: "ja", name: "日本語"),
        .init(code: "ko", name: "한국어"),
        .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"),
        .init(code: "es", name: "Español"),
        .init(code: "it", name: "Italiano"),
        .init(code: "pt", name: "Português"),
        .init(code: "ru", name: "Русский"),
        .init(code: "ar", name: "العربية")
    ]

    static let all = [chinese, english] + additional

    static func language(for code: String) -> TranslationLanguage {
        all.first(where: { $0.code == code }) ?? .init(code: code, name: code)
    }
}

struct TranslationResult: Equatable {
    let text: String
    let detectedLanguage: String?
    let targetLanguage: String
    let provider: TranslationProvider
}

struct TranslationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let sourceLanguage: String?
    let targetLanguage: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        sourceLanguage: String?,
        targetLanguage: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.createdAt = createdAt
    }
}

struct TranslationConfiguration: Equatable {
    let serviceOrder: [TranslationServiceID]
    let microsoftPublicEndpoint: String
    let microsoftSubscriptionEndpoint: String
    let microsoftKey: String
    let microsoftRegion: String
    let alibabaEndpoint: String
    let alibabaAccessKeyID: String
    let alibabaAccessKeySecret: String
    let llmBaseURL: String
    let llmAPIKey: String
    let llmModel: String
    let ollamaBaseURL: String
    let ollamaModel: String

    var hasMicrosoftSubscriptionConfiguration: Bool {
        !microsoftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasAlibabaConfiguration: Bool {
        !alibabaAccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !alibabaAccessKeySecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasLLMConfiguration: Bool {
        !llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !llmAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasOllamaConfiguration: Bool {
        !ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum LanguageDetector {
    static func automaticTarget(for text: String) -> TranslationLanguage {
        containsHanCharacter(text) ? .english : .chinese
    }

    static func containsHanCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }
}
