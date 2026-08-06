import AppKit
import AVFoundation
import Combine
import Foundation

enum SpeechPlaybackSource: Equatable {
    case mainPanel
    case selectionBubble
}

enum SpeechPlaybackState: Equatable {
    case idle
    case playing
    case paused
}

struct SpeechPlaybackStatus: Equatable {
    let source: SpeechPlaybackSource?
    let state: SpeechPlaybackState

    static let idle = SpeechPlaybackStatus(source: nil, state: .idle)
}

@MainActor
final class AppState: NSObject, ObservableObject {
    private enum Keys {
        static let history = "translation.history"
    }

    private struct CompletedTranslation {
        let sourceText: String
        let targetLanguage: String
        let result: TranslationResult
    }

    @Published var inputText = "" {
        didSet {
            guard !isRestoringHistory else { return }
            scheduleTranslation()
        }
    }
    @Published private(set) var translatedText = ""
    @Published private(set) var inputReplacementID = 0
    @Published private(set) var statusMessage = ""
    @Published private(set) var isTranslating = false
    @Published private(set) var history: [TranslationRecord] = []
    @Published private(set) var speechPlayback = SpeechPlaybackStatus.idle
    @Published var selectedTarget: TranslationLanguage?
    @Published var showsSettings = false

    let settings: SettingsStore

    var effectiveTarget: TranslationLanguage {
        selectedTarget ?? LanguageDetector.automaticTarget(for: inputText)
    }

    private let coordinator: TranslationCoordinator
    private let defaults: UserDefaults
    private var translationTask: Task<Void, Never>?
    private var translationGeneration = 0
    private var isRestoringHistory = false
    private var completedTranslation: CompletedTranslation?
    private var translatedLanguageCode: String?
    private var speechSynthesizer: NSSpeechSynthesizer?
    private var englishSpeechSynthesizer: AVSpeechSynthesizer?
    private var cachedEnglishVoice: AVSpeechSynthesisVoice?
    private var voicesByLanguage: [String: NSSpeechSynthesizer.VoiceName] = [:]
    private var activeSpeechEngine: SpeechEngine?
    private var activeSpeechText = ""
    private var activeEnglishUtterance: AVSpeechUtterance?

    private enum SpeechEngine {
        case appKit
        case avFoundation
    }

    init(
        settings: SettingsStore = SettingsStore(),
        coordinator: TranslationCoordinator = TranslationCoordinator(),
        defaults: UserDefaults = .standard
    ) {
        self.settings = settings
        self.coordinator = coordinator
        self.defaults = defaults
        super.init()
        loadHistory()
    }

    deinit {
        translationTask?.cancel()
        speechSynthesizer?.stopSpeaking()
        englishSpeechSynthesizer?.stopSpeaking(at: .immediate)
    }

    func translateNow() {
        cancelPendingTranslation()
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            translatedText = ""
            statusMessage = ""
            isTranslating = false
            return
        }
        startTranslation(
            text: text,
            target: effectiveTarget,
            delayNanoseconds: 0,
            commitsToHistory: false
        )
    }

    func submitTranslation() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target = effectiveTarget
        if let completedTranslation = completedTranslation,
           completedTranslation.sourceText == text,
           completedTranslation.targetLanguage == target.code {
            addHistory(source: text, result: completedTranslation.result)
            replaceInputText("")
            return
        }

        cancelPendingTranslation()
        startTranslation(
            text: text,
            target: target,
            delayNanoseconds: 0,
            commitsToHistory: true
        )
    }

    func setTarget(_ language: TranslationLanguage?) {
        selectedTarget = language
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translateNow()
    }

    func restore(_ record: TranslationRecord) {
        cancelPendingTranslation()
        stopSpeech(for: .mainPanel)
        isRestoringHistory = true
        inputText = record.sourceText
        inputReplacementID &+= 1
        selectedTarget = TranslationLanguage.language(for: record.targetLanguage)
        translatedText = record.translatedText
        translatedLanguageCode = record.targetLanguage
        completedTranslation = nil
        statusMessage = ""
        isRestoringHistory = false
        showsSettings = false
    }

    func clearHistory() {
        history = []
        defaults.removeObject(forKey: Keys.history)
    }

    func translateSelection(_ text: String) async throws -> TranslationResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = LanguageDetector.automaticTarget(for: cleaned)
        let result = try await coordinator.translate(
            text: cleaned,
            targetLanguage: target.code,
            configuration: settings.configuration
        )
        addHistory(source: cleaned, result: result)
        return result
    }

    func toggleTranslatedSpeech() {
        toggleSpeech(
            text: translatedText,
            languageCode: translatedLanguageCode,
            source: .mainPanel
        )
    }

    func toggleSpeech(
        text: String,
        languageCode: String?,
        source: SpeechPlaybackSource
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if speechPlayback.source == source, activeSpeechText == cleaned {
            switch speechPlayback.state {
            case .idle:
                break
            case .playing:
                pauseSpeech()
                return
            case .paused:
                continueSpeech()
                return
            }
        }

        stopSpeech()

        let resolvedLanguageCode = languageCode
            ?? (LanguageDetector.containsHanCharacter(cleaned) ? "zh-Hans" : "en")
        if Locale(
            identifier: speechLocaleIdentifier(for: resolvedLanguageCode)
        ).languageCode == "en" {
            startEnglishSpeech(cleaned, source: source)
            return
        }

        let synthesizer = speechSynthesizer ?? NSSpeechSynthesizer()
        speechSynthesizer = synthesizer
        synthesizer.delegate = self
        let voice = voice(for: resolvedLanguageCode) ?? NSSpeechSynthesizer.defaultVoice
        synthesizer.setVoice(voice)
        activeSpeechEngine = .appKit
        activeSpeechText = cleaned
        speechPlayback = SpeechPlaybackStatus(source: source, state: .playing)
        if !synthesizer.startSpeaking(cleaned) {
            finishSpeech(using: .appKit)
        }
    }

    func speechState(for source: SpeechPlaybackSource) -> SpeechPlaybackState {
        speechPlayback.source == source ? speechPlayback.state : .idle
    }

    func stopSpeech(for source: SpeechPlaybackSource? = nil) {
        guard source == nil || speechPlayback.source == source else { return }
        activeSpeechEngine = nil
        activeSpeechText = ""
        activeEnglishUtterance = nil
        speechPlayback = .idle
        speechSynthesizer?.delegate = nil
        speechSynthesizer?.stopSpeaking()
        speechSynthesizer = nil
        englishSpeechSynthesizer?.stopSpeaking(at: .immediate)
    }

    private func scheduleTranslation() {
        cancelPendingTranslation()
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            translatedText = ""
            translatedLanguageCode = nil
            completedTranslation = nil
            statusMessage = ""
            isTranslating = false
            return
        }
        startTranslation(
            text: text,
            target: effectiveTarget,
            delayNanoseconds: 450_000_000,
            commitsToHistory: false
        )
    }

    private func startTranslation(
        text: String,
        target: TranslationLanguage,
        delayNanoseconds: UInt64,
        commitsToHistory: Bool
    ) {
        let configuration = settings.configuration
        let generation = translationGeneration
        translationTask = Task { [weak self] in
            do {
                if delayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard let self = self,
                      !Task.isCancelled,
                      self.translationGeneration == generation else { return }
                self.isTranslating = true
                self.statusMessage = ""
                let result = try await self.coordinator.translate(
                    text: text,
                    targetLanguage: target.code,
                    configuration: configuration
                )
                guard !Task.isCancelled,
                      self.translationGeneration == generation,
                      self.inputText.trimmingCharacters(in: .whitespacesAndNewlines) == text else {
                    return
                }
                self.translatedText = result.text
                self.translatedLanguageCode = result.targetLanguage
                self.completedTranslation = CompletedTranslation(
                    sourceText: text,
                    targetLanguage: target.code,
                    result: result
                )
                self.isTranslating = false
                if commitsToHistory {
                    self.addHistory(source: text, result: result)
                    self.replaceInputText("")
                }
            } catch is CancellationError {
                guard self?.translationGeneration == generation else { return }
                self?.isTranslating = false
            } catch {
                guard !Task.isCancelled, self?.translationGeneration == generation else { return }
                self?.translatedText = ""
                self?.translatedLanguageCode = nil
                self?.completedTranslation = nil
                self?.isTranslating = false
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    private func cancelPendingTranslation() {
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
    }

    private func replaceInputText(_ text: String) {
        inputText = text
        inputReplacementID &+= 1
    }

    private func startEnglishSpeech(_ text: String, source: SpeechPlaybackSource) {
        let synthesizer = englishSpeechSynthesizer ?? AVSpeechSynthesizer()
        englishSpeechSynthesizer = synthesizer
        synthesizer.delegate = self

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredEnglishVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1
        utterance.volume = 1
        activeSpeechEngine = .avFoundation
        activeSpeechText = text
        activeEnglishUtterance = utterance
        speechPlayback = SpeechPlaybackStatus(source: source, state: .playing)
        synthesizer.speak(utterance)
    }

    private func pauseSpeech() {
        switch activeSpeechEngine {
        case .appKit:
            speechSynthesizer?.pauseSpeaking(at: .immediateBoundary)
            speechPlayback = SpeechPlaybackStatus(
                source: speechPlayback.source,
                state: .paused
            )
        case .avFoundation:
            guard englishSpeechSynthesizer?.pauseSpeaking(at: .immediate) == true else {
                return
            }
            speechPlayback = SpeechPlaybackStatus(
                source: speechPlayback.source,
                state: .paused
            )
        case nil:
            speechPlayback = .idle
        }
    }

    private func continueSpeech() {
        switch activeSpeechEngine {
        case .appKit:
            speechSynthesizer?.continueSpeaking()
            speechPlayback = SpeechPlaybackStatus(
                source: speechPlayback.source,
                state: .playing
            )
        case .avFoundation:
            guard englishSpeechSynthesizer?.continueSpeaking() == true else {
                return
            }
            speechPlayback = SpeechPlaybackStatus(
                source: speechPlayback.source,
                state: .playing
            )
        case nil:
            speechPlayback = .idle
        }
    }

    private func finishSpeech(using engine: SpeechEngine) {
        guard activeSpeechEngine == engine else { return }
        activeSpeechEngine = nil
        activeSpeechText = ""
        activeEnglishUtterance = nil
        speechPlayback = .idle
    }

    private func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        if let cachedEnglishVoice = cachedEnglishVoice {
            return cachedEnglishVoice
        }
        let defaultVoice = AVSpeechSynthesisVoice(language: "en-US")
        let defaultQuality = defaultVoice?.quality.rawValue ?? 0
        let enhancedVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.caseInsensitiveCompare("en-US") == .orderedSame
                && $0.quality.rawValue > defaultQuality
        }
        let selected = enhancedVoices.max { lhs, rhs in
            lhs.quality.rawValue < rhs.quality.rawValue
        } ?? defaultVoice
        cachedEnglishVoice = selected
        return selected
    }

    private func voice(for languageCode: String?) -> NSSpeechSynthesizer.VoiceName? {
        guard let languageCode = languageCode else { return nil }
        let localeIdentifier = speechLocaleIdentifier(for: languageCode)
        let requestedLanguage = Locale(identifier: localeIdentifier).languageCode
            ?? localeIdentifier
        if let cached = voicesByLanguage[requestedLanguage] {
            return cached
        }
        guard let voice = NSSpeechSynthesizer.availableVoices.first(where: { voice in
            guard let voiceLocale = NSSpeechSynthesizer.attributes(forVoice: voice)[
                .localeIdentifier
            ] as? String else {
                return false
            }
            return Locale(identifier: voiceLocale).languageCode == requestedLanguage
        }) else {
            return nil
        }
        voicesByLanguage[requestedLanguage] = voice
        return voice
    }

    private func speechLocaleIdentifier(for languageCode: String) -> String {
        switch languageCode {
        case "en": return "en-US"
        case "zh-Hans", "zh": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        default: return languageCode
        }
    }

    private func addHistory(source: String, result: TranslationResult) {
        let record = TranslationRecord(
            sourceText: source,
            translatedText: result.text,
            sourceLanguage: result.detectedLanguage,
            targetLanguage: result.targetLanguage
        )
        if let first = history.first,
           first.sourceText == record.sourceText,
           first.translatedText == record.translatedText,
           first.targetLanguage == record.targetLanguage {
            return
        }
        history.insert(record, at: 0)
        if history.count > 100 {
            history.removeLast(history.count - 100)
        }
        persistHistory()
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: Keys.history),
              let records = try? JSONDecoder().decode([TranslationRecord].self, from: data) else {
            return
        }
        history = records
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Keys.history)
    }
}

extension AppState: NSSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ sender: NSSpeechSynthesizer,
        didFinishSpeaking finishedSpeaking: Bool
    ) {
        guard sender === speechSynthesizer else { return }
        finishSpeech(using: .appKit)
    }
}

extension AppState: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        guard utterance === activeEnglishUtterance else { return }
        finishSpeech(using: .avFoundation)
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        guard utterance === activeEnglishUtterance else { return }
        finishSpeech(using: .avFoundation)
    }
}
