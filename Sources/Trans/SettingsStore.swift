import AppKit
import ApplicationServices
import Combine
import Foundation

final class SettingsStore: ObservableObject {
    private enum Keys {
        static let provider = "translation.provider"
        static let servicePreferences = "translation.servicePreferences"
        static let microsoftPublicEndpoint = "translation.microsoft.publicEndpoint"
        static let microsoftSubscriptionEndpoint = "translation.microsoft.subscriptionEndpoint"
        static let microsoftRegion = "translation.microsoft.region"
        static let alibabaEndpoint = "translation.alibaba.endpoint"
        static let llmBaseURL = "translation.llm.baseURL"
        static let llmModel = "translation.llm.model"
        static let ollamaBaseURL = "translation.ollama.baseURL"
        static let ollamaModel = "translation.ollama.model"
        static let selectionEnabled = "selection.enabled"
        static let microsoftKey = "microsoft-key"
        static let alibabaAccessKeyID = "alibaba-access-key-id"
        static let alibabaAccessKeySecret = "alibaba-access-key-secret"
        static let llmAPIKey = "llm-api-key"
    }

    @Published var servicePreferences: [TranslationServicePreference]
    @Published var microsoftPublicEndpoint: String
    @Published var microsoftSubscriptionEndpoint: String
    @Published var microsoftKey: String
    @Published var microsoftRegion: String
    @Published var alibabaEndpoint: String
    @Published var alibabaAccessKeyID: String
    @Published var alibabaAccessKeySecret: String
    @Published var llmBaseURL: String
    @Published var llmAPIKey: String
    @Published var llmModel: String
    @Published var ollamaBaseURL: String
    @Published var ollamaModel: String
    @Published var selectionEnabled: Bool
    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var saveMessage = ""

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMicrosoftKey = KeychainStore.string(for: Keys.microsoftKey)
        microsoftKey = storedMicrosoftKey
        microsoftPublicEndpoint = defaults.string(forKey: Keys.microsoftPublicEndpoint)
            ?? TranslationDefaults.microsoftPublicEndpoint
        microsoftSubscriptionEndpoint = defaults.string(forKey: Keys.microsoftSubscriptionEndpoint)
            ?? TranslationDefaults.microsoftSubscriptionEndpoint
        microsoftRegion = defaults.string(forKey: Keys.microsoftRegion) ?? ""
        alibabaEndpoint = defaults.string(forKey: Keys.alibabaEndpoint)
            ?? TranslationDefaults.alibabaEndpoint
        alibabaAccessKeyID = KeychainStore.string(for: Keys.alibabaAccessKeyID)
        alibabaAccessKeySecret = KeychainStore.string(for: Keys.alibabaAccessKeySecret)
        llmBaseURL = defaults.string(forKey: Keys.llmBaseURL) ?? TranslationDefaults.llmBaseURL
        llmAPIKey = KeychainStore.string(for: Keys.llmAPIKey)
        llmModel = defaults.string(forKey: Keys.llmModel) ?? TranslationDefaults.llmModel
        ollamaBaseURL = defaults.string(forKey: Keys.ollamaBaseURL)
            ?? TranslationDefaults.ollamaBaseURL
        ollamaModel = defaults.string(forKey: Keys.ollamaModel)
            ?? TranslationDefaults.ollamaModel
        selectionEnabled = defaults.object(forKey: Keys.selectionEnabled) as? Bool ?? true
        accessibilityTrusted = AXIsProcessTrusted()

        if let data = defaults.data(forKey: Keys.servicePreferences),
           let decoded = try? JSONDecoder().decode(
               [TranslationServicePreference].self,
               from: data
           ) {
            servicePreferences = TranslationServicePreference.normalized(decoded)
        } else if let legacyValue = defaults.string(forKey: Keys.provider) {
            let legacyProvider = TranslationProvider(rawValue: legacyValue) ?? .automatic
            servicePreferences = Self.migratedPreferences(
                from: legacyProvider,
                hasMicrosoftKey: !storedMicrosoftKey.isEmpty
            )
        } else {
            servicePreferences = TranslationServicePreference.defaultOrder
        }
    }

    var configuration: TranslationConfiguration {
        TranslationConfiguration(
            serviceOrder: servicePreferences.filter(\.isEnabled).map(\.id),
            microsoftPublicEndpoint: trimmed(microsoftPublicEndpoint),
            microsoftSubscriptionEndpoint: trimmed(microsoftSubscriptionEndpoint),
            microsoftKey: trimmed(microsoftKey),
            microsoftRegion: trimmed(microsoftRegion),
            alibabaEndpoint: trimmed(alibabaEndpoint),
            alibabaAccessKeyID: trimmed(alibabaAccessKeyID),
            alibabaAccessKeySecret: trimmed(alibabaAccessKeySecret),
            llmBaseURL: trimmed(llmBaseURL),
            llmAPIKey: trimmed(llmAPIKey),
            llmModel: trimmed(llmModel),
            ollamaBaseURL: trimmed(ollamaBaseURL),
            ollamaModel: trimmed(ollamaModel)
        )
    }

    func save() {
        servicePreferences = TranslationServicePreference.normalized(servicePreferences)
        microsoftPublicEndpoint = trimmed(microsoftPublicEndpoint)
        microsoftSubscriptionEndpoint = trimmed(microsoftSubscriptionEndpoint)
        microsoftKey = trimmed(microsoftKey)
        microsoftRegion = trimmed(microsoftRegion)
        alibabaEndpoint = trimmed(alibabaEndpoint)
        alibabaAccessKeyID = trimmed(alibabaAccessKeyID)
        alibabaAccessKeySecret = trimmed(alibabaAccessKeySecret)
        llmBaseURL = trimmed(llmBaseURL)
        llmAPIKey = trimmed(llmAPIKey)
        llmModel = trimmed(llmModel)
        ollamaBaseURL = trimmed(ollamaBaseURL)
        ollamaModel = trimmed(ollamaModel)

        if let serviceData = try? JSONEncoder().encode(servicePreferences) {
            defaults.set(serviceData, forKey: Keys.servicePreferences)
        }
        defaults.set(microsoftPublicEndpoint, forKey: Keys.microsoftPublicEndpoint)
        defaults.set(microsoftSubscriptionEndpoint, forKey: Keys.microsoftSubscriptionEndpoint)
        defaults.set(microsoftRegion, forKey: Keys.microsoftRegion)
        defaults.set(alibabaEndpoint, forKey: Keys.alibabaEndpoint)
        defaults.set(llmBaseURL, forKey: Keys.llmBaseURL)
        defaults.set(llmModel, forKey: Keys.llmModel)
        defaults.set(ollamaBaseURL, forKey: Keys.ollamaBaseURL)
        defaults.set(ollamaModel, forKey: Keys.ollamaModel)
        defaults.set(selectionEnabled, forKey: Keys.selectionEnabled)

        let microsoftSaved = KeychainStore.set(microsoftKey, for: Keys.microsoftKey)
        let alibabaAccessKeyIDSaved = KeychainStore.set(
            alibabaAccessKeyID,
            for: Keys.alibabaAccessKeyID
        )
        let alibabaAccessKeySecretSaved = KeychainStore.set(
            alibabaAccessKeySecret,
            for: Keys.alibabaAccessKeySecret
        )
        let llmSaved = KeychainStore.set(llmAPIKey, for: Keys.llmAPIKey)
        saveMessage = microsoftSaved
            && alibabaAccessKeyIDSaved
            && alibabaAccessKeySecretSaved
            && llmSaved
            ? "已保存"
            : "密钥保存失败"
    }

    func refreshSystemPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        refreshSystemPermissions()
    }

    func openAccessibilitySettings() {
        requestAccessibilityPermission()
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func migratedPreferences(
        from provider: TranslationProvider,
        hasMicrosoftKey: Bool
    ) -> [TranslationServicePreference] {
        let microsoftPrimary: TranslationServiceID = hasMicrosoftKey
            ? .microsoftSubscription
            : .microsoftPublic
        let order: [TranslationServiceID]
        switch provider {
        case .automatic:
            let microsoftFallback: TranslationServiceID = hasMicrosoftKey
                ? .microsoftPublic
                : .microsoftSubscription
            order = [microsoftPrimary, .llm, microsoftFallback, .alibaba, .ollama]
        case .microsoft:
            let microsoftFallback: TranslationServiceID = hasMicrosoftKey
                ? .microsoftPublic
                : .microsoftSubscription
            order = [microsoftPrimary, microsoftFallback, .alibaba, .llm, .ollama]
        case .alibaba:
            order = [
                .alibaba,
                microsoftPrimary,
                .llm,
                hasMicrosoftKey ? .microsoftPublic : .microsoftSubscription,
                .ollama
            ]
        case .llm:
            order = [
                .llm,
                microsoftPrimary,
                .alibaba,
                hasMicrosoftKey ? .microsoftPublic : .microsoftSubscription,
                .ollama
            ]
        case .ollama:
            order = [
                .ollama,
                microsoftPrimary,
                .alibaba,
                .llm,
                hasMicrosoftKey ? .microsoftPublic : .microsoftSubscription
            ]
        }
        return order.map { TranslationServicePreference(id: $0, isEnabled: true) }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
