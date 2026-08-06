import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainPanelView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            HistorySidebar(state: state)
                .frame(width: 220)

            Divider()

            if state.showsSettings {
                SettingsView(state: state, settings: state.settings)
            } else {
                TranslationWorkspace(state: state)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HistorySidebar: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史记录")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !state.history.isEmpty {
                    Button {
                        state.clearHistory()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("清空历史记录")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            if state.history.isEmpty {
                Spacer()
                Text("暂无记录")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.history) { record in
                            Button {
                                state.restore(record)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.sourceText)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(record.translatedText)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(HistoryButtonStyle())
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 8)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
}

private struct HistoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.09) : Color.clear)
            )
    }
}

private struct TranslationWorkspace: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("翻译")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                targetMenu
                Button {
                    state.stopSpeech(for: .mainPanel)
                    state.showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("设置")
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Divider()

            TranslationInputEditor(
                text: $state.inputText,
                replacementID: state.inputReplacementID,
                onSubmit: state.submitTranslation
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ZStack(alignment: .topLeading) {
                ScrollView {
                    Text(state.translatedText)
                        .font(.system(size: 16))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                        .padding(.trailing, 60)
                }

                if state.isTranslating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(16)
                } else if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(16)
                } else if state.translatedText.isEmpty {
                    Text("翻译结果")
                        .font(.system(size: 16))
                        .foregroundColor(Color(nsColor: .placeholderTextColor))
                        .padding(16)
                }

                if !state.translatedText.isEmpty && !state.isTranslating {
                    HStack(spacing: 4) {
                        Spacer()
                        Button {
                            state.toggleTranslatedSpeech()
                        } label: {
                            Image(systemName: speechButtonSymbolName)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .help(speechButtonLabel)
                        .accessibilityLabel(speechButtonLabel)

                        Button {
                            state.stopSpeech(for: .mainPanel)
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .opacity(mainSpeechState == .idle ? 0 : 1)
                        .allowsHitTesting(mainSpeechState != .idle)
                        .help("停止朗读")
                        .accessibilityLabel("停止朗读")
                    }
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var mainSpeechState: SpeechPlaybackState {
        state.speechState(for: .mainPanel)
    }

    private var speechButtonSymbolName: String {
        switch mainSpeechState {
        case .idle: return "speaker.wave.2"
        case .playing: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    private var speechButtonLabel: String {
        switch mainSpeechState {
        case .idle: return "朗读结果"
        case .playing: return "暂停朗读"
        case .paused: return "继续朗读"
        }
    }

    private var targetMenu: some View {
        Menu {
            Button("自动（中英互译）") {
                state.setTarget(nil)
            }
            Divider()
            Button(TranslationLanguage.chinese.name) {
                state.setTarget(.chinese)
            }
            Button(TranslationLanguage.english.name) {
                state.setTarget(.english)
            }
            Divider()
            Menu("更多语言") {
                ForEach(TranslationLanguage.additional) { language in
                    Button(language.name) {
                        state.setTarget(language)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.selectedTarget?.name ?? "自动 · \(state.effectiveTarget.name)")
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct TranslationInputEditor: NSViewRepresentable {
    @Binding var text: String
    let replacementID: Int
    let onSubmit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> TranslationInputEditorView {
        let editor = TranslationInputEditorView()
        editor.textView.delegate = context.coordinator
        context.coordinator.editor = editor
        editor.setText(text)
        context.coordinator.appliedReplacementID = replacementID
        return editor
    }

    func updateNSView(_ editor: TranslationInputEditorView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.appliedReplacementID != replacementID else {
            editor.updatePlaceholder()
            return
        }
        context.coordinator.appliedReplacementID = replacementID
        editor.setText(text)
    }

    static func dismantleNSView(
        _ editor: TranslationInputEditorView,
        coordinator: Coordinator
    ) {
        editor.textView.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranslationInputEditor
        weak var editor: TranslationInputEditorView?
        var appliedReplacementID: Int?

        init(parent: TranslationInputEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            editor?.updatePlaceholder()
            guard !textView.hasMarkedText() else { return }
            parent.text = textView.string
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
                  !textView.hasMarkedText() else {
                return false
            }
            parent.onSubmit()
            return true
        }
    }
}

private final class TranslationInputEditorView: NSView {
    private static let contentInset = NSSize(width: 16, height: 16)

    let textView = NSTextView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let placeholder = NSTextField(labelWithString: "输入文本")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        textView.font = .systemFont(ofSize: 16)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = Self.contentInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("翻译输入")

        placeholder.font = .systemFont(ofSize: 16)
        placeholder.textColor = .placeholderTextColor
        placeholder.isSelectable = false

        scrollView.documentView = textView
        addSubview(scrollView)
        addSubview(placeholder)
        updatePlaceholder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds

        let contentSize = scrollView.contentSize
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        if textView.frame.width != contentSize.width
            || textView.frame.height < contentSize.height {
            textView.setFrameSize(
                NSSize(
                    width: contentSize.width,
                    height: max(contentSize.height, textView.frame.height)
                )
            )
        }

        placeholder.sizeToFit()
        placeholder.frame.origin = NSPoint(
            x: Self.contentInset.width,
            y: Self.contentInset.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)
        return hitView === placeholder ? textView : hitView
    }

    func setText(_ text: String) {
        if textView.string != text {
            textView.string = text
        }
        updatePlaceholder()
    }

    func updatePlaceholder() {
        placeholder.isHidden = !textView.string.isEmpty
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @State private var draggedServiceID: TranslationServiceID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    state.showsSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("返回翻译")
                Text("设置")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !settings.saveMessage.isEmpty {
                    Text(settings.saveMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Button("保存") {
                    settings.save()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("服务优先级")
                            .font(.system(size: 12, weight: .semibold))

                        ForEach($settings.servicePreferences) { $preference in
                            TranslationServiceSettingsRow(
                                preference: $preference,
                                settings: settings,
                                draggedServiceID: $draggedServiceID
                            )
                            .onDrop(
                                of: [UTType.text],
                                delegate: ServicePriorityDropDelegate(
                                    targetID: preference.id,
                                    preferences: $settings.servicePreferences,
                                    draggedServiceID: $draggedServiceID
                                )
                            )

                            if preference.id != settings.servicePreferences.last?.id {
                                Divider()
                            }
                        }
                    }

                    HStack {
                        Toggle("划词翻译", isOn: $settings.selectionEnabled)
                            .toggleStyle(.switch)
                        Spacer()
                    }

                    HStack {
                        Text("辅助功能")
                            .font(.system(size: 12))
                        Spacer()
                        if settings.accessibilityTrusted {
                            Text("已授权")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Button("授权") {
                                settings.openAccessibilitySettings()
                            }
                        }
                    }

                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            settings.refreshSystemPermissions()
        }
    }
}

private struct TranslationServiceSettingsRow: View {
    @Binding var preference: TranslationServicePreference
    @ObservedObject var settings: SettingsStore
    @Binding var draggedServiceID: TranslationServiceID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Toggle("", isOn: $preference.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text(preference.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let tag = preference.displayTag {
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help(tag)
                }
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggedServiceID = preference.id
                        return NSItemProvider(object: preference.id.rawValue as NSString)
                    }
                    .help("拖动排序")
            }

            configurationFields
                .padding(.leading, 36)
        }
        .padding(.vertical, 12)
        .opacity(draggedServiceID == preference.id ? 0.55 : 1)
    }

    @ViewBuilder
    private var configurationFields: some View {
        VStack(spacing: 8) {
            SettingField(label: "显示名称", text: customNameBinding)
            SettingField(label: "Tag", text: tagBinding)
            providerConfigurationFields
        }
    }

    @ViewBuilder
    private var providerConfigurationFields: some View {
        switch preference.id {
        case .microsoftPublic:
            SettingField(label: "服务地址", text: $settings.microsoftPublicEndpoint)
        case .microsoftSubscription:
            VStack(spacing: 8) {
                SettingField(label: "服务地址", text: $settings.microsoftSubscriptionEndpoint)
                SettingField(
                    label: "订阅密钥",
                    supportsPaste: true,
                    isSecure: true,
                    text: $settings.microsoftKey
                )
                SettingField(label: "区域", text: $settings.microsoftRegion)
            }
        case .alibaba:
            VStack(spacing: 8) {
                SettingField(label: "服务地址", text: $settings.alibabaEndpoint)
                SettingField(
                    label: "AccessKey ID",
                    supportsPaste: true,
                    text: $settings.alibabaAccessKeyID
                )
                SettingField(
                    label: "AccessKey Secret",
                    supportsPaste: true,
                    isSecure: true,
                    text: $settings.alibabaAccessKeySecret
                )
            }
        case .llm:
            VStack(spacing: 8) {
                SettingField(label: "Base URL", text: $settings.llmBaseURL)
                SettingField(
                    label: "API Key",
                    supportsPaste: true,
                    isSecure: true,
                    text: $settings.llmAPIKey
                )
                SettingField(label: "模型", text: $settings.llmModel)
            }
        case .ollama:
            VStack(spacing: 8) {
                SettingField(label: "服务地址", text: $settings.ollamaBaseURL)
                SettingField(label: "模型", text: $settings.ollamaModel)
            }
        }
    }

    private var customNameBinding: Binding<String> {
        Binding(
            get: { preference.customName ?? preference.id.title },
            set: { preference.customName = $0 }
        )
    }

    private var tagBinding: Binding<String> {
        Binding(
            get: { preference.tag ?? "" },
            set: { preference.tag = $0 }
        )
    }
}

private struct ServicePriorityDropDelegate: DropDelegate {
    let targetID: TranslationServiceID
    @Binding var preferences: [TranslationServicePreference]
    @Binding var draggedServiceID: TranslationServiceID?

    func dropEntered(info: DropInfo) {
        guard let draggedServiceID = draggedServiceID,
              draggedServiceID != targetID,
              let sourceIndex = preferences.firstIndex(where: { $0.id == draggedServiceID }),
              let targetIndex = preferences.firstIndex(where: { $0.id == targetID }) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
            preferences.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedServiceID = nil
        return true
    }
}

private struct SettingField: View {
    let label: String
    var supportsPaste = false
    var isSecure = false
    @Binding var text: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            if isSecure {
                SecureField("", text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            if supportsPaste {
                Button {
                    guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
                        return
                    }
                    text = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .help("粘贴")
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func scrollContentBackgroundIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
