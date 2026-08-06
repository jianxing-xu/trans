import AppKit
import ApplicationServices
import Combine
import os.log
import SwiftUI

private let selectionLog = OSLog(subsystem: "com.trans.app", category: "Selection")

@MainActor
final class SelectionTranslationController {
    private let state: AppState
    private let bubbleController: SelectionBubbleController
    private var selectionPollTimer: Timer?
    private var selectionTask: Task<Void, Never>?
    private var mouseSelectionTask: Task<Void, Never>?
    private var mouseUpMonitor: Any?
    private var dismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var pointerDownLocation: NSPoint?
    private var isPointerDown = false
    private var pendingSelectionFingerprint: String?
    private var shownSelectionFingerprint: String?
    private var suppressedSelectionFingerprint: String?

    init(state: AppState) {
        self.state = state
        bubbleController = SelectionBubbleController(state: state)
    }

    func start() {
        state.settings.refreshSystemPermissions()
        guard state.settings.accessibilityTrusted else {
            os_log("Accessibility permission unavailable", log: selectionLog, type: .error)
            state.settings.requestAccessibilityPermission()
            return
        }
        guard selectionPollTimer == nil else { return }
        let timer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(selectionPollTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        selectionPollTimer = timer
        installGlobalMonitors()
        os_log("Selection polling started", log: selectionLog, type: .info)
        pollSelection()
    }

    @objc private func selectionPollTimerFired() {
        pollSelection()
    }

    func stop() {
        selectionPollTimer?.invalidate()
        selectionPollTimer = nil
        selectionTask?.cancel()
        mouseSelectionTask?.cancel()
        if let mouseUpMonitor = mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        if let dismissMonitor = dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
        }
        if let localDismissMonitor = localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
        }
        mouseUpMonitor = nil
        dismissMonitor = nil
        localDismissMonitor = nil
        pointerDownLocation = nil
        isPointerDown = false
        pendingSelectionFingerprint = nil
        shownSelectionFingerprint = nil
        suppressedSelectionFingerprint = nil
        bubbleController.hide()
    }

    private func pollSelection() {
        guard state.settings.selectionEnabled else {
            bubbleController.hide()
            return
        }
        guard !isPointerDown, !bubbleController.isInteracting else { return }
        guard let selection = Self.currentSelection() else {
            selectionTask?.cancel()
            pendingSelectionFingerprint = nil
            if !bubbleController.isVisible {
                shownSelectionFingerprint = nil
            }
            return
        }
        let fingerprint = Self.fingerprint(for: selection)
        guard fingerprint != shownSelectionFingerprint,
              fingerprint != pendingSelectionFingerprint,
              fingerprint != suppressedSelectionFingerprint else {
            return
        }

        pendingSelectionFingerprint = fingerprint
        os_log("Selection candidate detected", log: selectionLog, type: .info)
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self = self, !Task.isCancelled else {
                return
            }
            guard let confirmedSelection = Self.currentSelection(),
                  Self.fingerprint(for: confirmedSelection) == fingerprint else {
                self.pendingSelectionFingerprint = nil
                return
            }
            let mouseLocation = NSEvent.mouseLocation
            let anchor = NSPoint(x: mouseLocation.x + 6, y: mouseLocation.y + 8)
            self.pendingSelectionFingerprint = nil
            self.shownSelectionFingerprint = fingerprint
            self.suppressedSelectionFingerprint = nil
            self.bubbleController.show(text: confirmedSelection.text, near: anchor)
            os_log("Selection bubble displayed", log: selectionLog, type: .info)
        }
    }

    private func installGlobalMonitors() {
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let quartzLocation = event.cgEvent?.location
            Task { @MainActor in
                guard let self = self else { return }
                let location = quartzLocation.flatMap { point in
                    Self.appKitPoint(fromQuartzPoint: point)
                } ?? NSEvent.mouseLocation
                if self.bubbleController.isInteracting
                    || self.bubbleController.contains(screenPoint: location) {
                    if event.type == .leftMouseDown {
                        self.bubbleController.beginInteraction()
                    }
                    os_log("Global event ignored inside bubble", log: selectionLog, type: .info)
                    return
                }
                self.handleExternalOperation(event, at: location, source: "global")
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let quartzLocation = event.cgEvent?.location
            Task { @MainActor in
                guard let self = self else { return }
                let location = quartzLocation.flatMap { point in
                    Self.appKitPoint(fromQuartzPoint: point)
                } ?? NSEvent.mouseLocation
                if self.bubbleController.isInteracting
                    || self.bubbleController.contains(screenPoint: location) {
                    self.bubbleController.scheduleEndInteraction()
                    os_log("Global mouse up ignored inside bubble", log: selectionLog, type: .info)
                    return
                }
                self.handleExternalMouseUp(event, at: location)
            }
        }
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self = self else { return event }
            if self.bubbleController.contains(event: event) {
                if event.type == .leftMouseDown {
                    self.bubbleController.beginInteraction()
                } else if event.type == .leftMouseUp {
                    self.bubbleController.scheduleEndInteraction()
                }
            } else if event.type != .leftMouseUp {
                self.handleExternalOperation(
                    event,
                    at: NSEvent.mouseLocation,
                    source: "local"
                )
            }
            return event
        }
    }

    private func handleExternalOperation(
        _ event: NSEvent,
        at mouseLocation: NSPoint,
        source: String
    ) {
        if bubbleController.isVisible {
            os_log(
                "Bubble dismissed by %{public}@ %{public}@",
                log: selectionLog,
                type: .info,
                source,
                String(describing: event.type)
            )
        }
        suppressedSelectionFingerprint = shownSelectionFingerprint
            ?? pendingSelectionFingerprint
            ?? suppressedSelectionFingerprint
        selectionTask?.cancel()
        mouseSelectionTask?.cancel()
        pendingSelectionFingerprint = nil
        shownSelectionFingerprint = nil
        bubbleController.hide()

        if event.type == .leftMouseDown {
            isPointerDown = true
            pointerDownLocation = mouseLocation
        } else {
            isPointerDown = false
            pointerDownLocation = nil
        }
    }

    private func handleExternalMouseUp(_ event: NSEvent, at mouseLocation: NSPoint) {
        let dragDistance: CGFloat
        if let start = pointerDownLocation {
            dragDistance = hypot(mouseLocation.x - start.x, mouseLocation.y - start.y)
        } else {
            dragDistance = 0
        }
        isPointerDown = false
        pointerDownLocation = nil
        let isSelectionGesture = dragDistance >= 3 || event.clickCount >= 2
        guard isSelectionGesture else { return }

        mouseSelectionTask?.cancel()
        mouseSelectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard let self = self, !Task.isCancelled else { return }
            var selection = Self.currentSelection()
            if selection == nil {
                selection = await Self.selectionUsingClipboardFallback()
            }
            guard let selection = selection, !Task.isCancelled else { return }
            let fingerprint = Self.fingerprint(for: selection)
            self.selectionTask?.cancel()
            self.pendingSelectionFingerprint = nil
            self.shownSelectionFingerprint = fingerprint
            self.suppressedSelectionFingerprint = nil
            self.bubbleController.show(
                text: selection.text,
                near: NSPoint(x: mouseLocation.x + 6, y: mouseLocation.y + 8)
            )
            os_log("Selection bubble displayed after mouse gesture", log: selectionLog, type: .info)
        }
    }

    private static func fingerprint(
        for selection: (text: String, topRight: NSPoint?)
    ) -> String {
        selection.text
    }

    private static func currentSelection() -> (text: String, topRight: NSPoint?)? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue = focusedValue else {
            return nil
        }
        let focusedElement = focusedValue as! AXUIElement
        var focusedProcessIdentifier = pid_t(0)
        if AXUIElementGetPid(focusedElement, &focusedProcessIdentifier) == .success,
           focusedProcessIdentifier == pid_t(ProcessInfo.processInfo.processIdentifier) {
            return nil
        }

        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success,
        let selectedText = selectedTextValue as? String else {
            return nil
        }
        let cleaned = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 5_000 else { return nil }

        return (cleaned, selectionTopRight(for: focusedElement))
    }

    private static func selectionTopRight(for element: AXUIElement) -> NSPoint? {
        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
        let selectedRangeValue = selectedRangeValue else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selectedRangeValue,
            &boundsValue
        ) == .success,
        let boundsValue = boundsValue else {
            return nil
        }

        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds) else {
            return nil
        }
        let quartzPoint = CGPoint(x: bounds.maxX, y: bounds.minY)
        return appKitPoint(fromQuartzPoint: quartzPoint)
    }

    private static func appKitPoint(fromQuartzPoint point: CGPoint) -> NSPoint? {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                continue
            }
            let quartzFrame = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            guard quartzFrame.contains(point) else { continue }
            return NSPoint(
                x: screen.frame.minX + point.x - quartzFrame.minX,
                y: screen.frame.maxY - (point.y - quartzFrame.minY)
            )
        }
        return nil
    }

    private static func selectionUsingClipboardFallback() async -> (text: String, topRight: NSPoint?)? {
        guard AXIsProcessTrusted() else { return nil }
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item in
            clonePasteboardItem(item)
        } ?? []
        let previousChangeCount = pasteboard.changeCount

        let eventSource = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 8, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 8, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 180_000_000)
        let copiedText = pasteboard.changeCount != previousChangeCount
            ? pasteboard.string(forType: .string)
            : nil

        pasteboard.clearContents()
        if !previousItems.isEmpty {
            pasteboard.writeObjects(previousItems)
        }

        guard let copiedText = copiedText else { return nil }
        let cleaned = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= 5_000 else { return nil }
        return (cleaned, nil)
    }

    private static func clonePasteboardItem(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let clone = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) {
                clone.setData(data, forType: type)
            }
        }
        return clone
    }

}

@MainActor
private final class SelectionBubbleModel: ObservableObject {
    enum Phase {
        case ready
        case translating
        case result
        case error
    }

    @Published private(set) var displayText = "CUE"
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var speechState: SpeechPlaybackState = .idle

    private let state: AppState
    private var sourceText = ""
    private var resultLanguageCode: String?
    private var task: Task<Void, Never>?
    private var speechCancellable: AnyCancellable?

    init(state: AppState) {
        self.state = state
        speechCancellable = state.$speechPlayback
            .map { playback in
                playback.source == .selectionBubble ? playback.state : .idle
            }
            .removeDuplicates()
            .sink { [weak self] speechState in
                self?.speechState = speechState
            }
    }

    deinit {
        task?.cancel()
    }

    func reset(text: String) {
        task?.cancel()
        state.stopSpeech(for: .selectionBubble)
        sourceText = text
        resultLanguageCode = nil
        displayText = "CUE"
        phase = .ready
    }

    func cancel() {
        task?.cancel()
        state.stopSpeech(for: .selectionBubble)
        resultLanguageCode = nil
        displayText = "CUE"
        phase = .ready
    }

    func activate() {
        switch phase {
        case .ready, .error:
            translate()
        case .translating, .result:
            break
        }
    }

    func speakResult() {
        guard phase == .result else { return }
        state.toggleSpeech(
            text: displayText,
            languageCode: resultLanguageCode,
            source: .selectionBubble
        )
    }

    private func translate() {
        displayText = "TRANS..."
        phase = .translating
        os_log("Selection translation started", log: selectionLog, type: .info)
        task = Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await self.state.translateSelection(self.sourceText)
                guard !Task.isCancelled else { return }
                self.displayText = result.text
                self.resultLanguageCode = result.targetLanguage
                self.phase = .result
                os_log("Selection translation completed", log: selectionLog, type: .info)
            } catch is CancellationError {
                return
            } catch {
                self.displayText = "重试"
                self.phase = .error
                os_log(
                    "Selection translation failed: %{public}@",
                    log: selectionLog,
                    type: .error,
                    error.localizedDescription
                )
            }
        }
    }
}

private struct SelectionBubbleView: View {
    @ObservedObject var model: SelectionBubbleModel

    private let bubbleBackground = Color(
        red: 51.0 / 255.0,
        green: 51.0 / 255.0,
        blue: 51.0 / 255.0
    )

    var body: some View {
        compactButton
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bubbleBackground)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var compactButton: some View {
        Button {
            model.activate()
        } label: {
            Text(model.displayText)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

}

enum SelectionResultTextStyle {
    static let font = NSFont.systemFont(ofSize: 15, weight: .medium)
    static let textContainerInset = NSSize(width: 4, height: 1)
    static let dragHandleSize = NSSize(width: 14, height: 14)
    static let speechButtonSize = NSSize(width: 20, height: 18)
    static let dragHandleSpacing: CGFloat = 2
    static let textMeasurementSlack: CGFloat = 1

    static var firstLineAccessoryWidth: CGFloat {
        dragHandleSize.width + speechButtonSize.width + dragHandleSpacing
    }

    static var firstLineAccessoryHeight: CGFloat {
        max(dragHandleSize.height, speechButtonSize.height)
    }

    static var paragraphStyle: NSParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        return paragraphStyle
    }

    static var attributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func bubbleWidth(
        for text: String,
        maximumWidth: CGFloat,
        minimumWidth: CGFloat = 48
    ) -> CGFloat {
        let lineWidths = text.components(separatedBy: .newlines).map {
            ceil(($0 as NSString).size(withAttributes: attributes).width)
        }
        let widestLineWidth = lineWidths.max() ?? 0
        let firstLineWidth = (lineWidths.first ?? 0) + firstLineAccessoryWidth
        let contentWidth = max(widestLineWidth, firstLineWidth) + textMeasurementSlack
        let horizontalPadding = textContainerInset.width * 2
        return min(maximumWidth, max(minimumWidth, contentWidth + horizontalPadding))
    }
}

@MainActor
private final class SelectionResultScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor
private final class SelectionResultTextView: NSTextView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount > 1 || isPointOverText(event.locationInWindow) else {
            if let panel = window as? SelectionPanel {
                panel.performBubbleDrag(with: event)
            } else {
                window?.performDrag(with: event)
            }
            return
        }

        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func isPointOverText(_ windowPoint: NSPoint) -> Bool {
        guard !string.isEmpty,
              let textContainer = textContainer,
              let layoutManager = layoutManager else {
            return false
        }

        var point = convert(windowPoint, from: nil)
        point.x -= textContainerInset.width
        point.y -= textContainerInset.height
        guard point.x >= 0, point.y >= 0 else { return false }

        let glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        guard glyphIndex < layoutManager.numberOfGlyphs else { return false }
        return layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        ).contains(point)
    }
}

@MainActor
private final class SelectionBubbleDragHandle: NSImageView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? SelectionPanel {
            panel.performBubbleDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
private final class SelectionBubbleActionButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
private final class SelectionBubbleResultView: NSView {
    private let scrollView = SelectionResultScrollView()
    private let textView = SelectionResultTextView()
    private let speechButton = SelectionBubbleActionButton()
    private let dragHandle = SelectionBubbleDragHandle()
    private var displayedText = ""
    var speakHandler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor(
            calibratedRed: 51.0 / 255.0,
            green: 51.0 / 255.0,
            blue: 51.0 / 255.0,
            alpha: 1
        ).cgColor
        layer?.cornerRadius = 3
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.masksToBounds = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.defaultParagraphStyle = SelectionResultTextStyle.paragraphStyle
        textView.textContainerInset = SelectionResultTextStyle.textContainerInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.maximumNumberOfLines = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 1,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        let clickRecognizer = NSClickGestureRecognizer(
            target: self,
            action: #selector(copyDisplayedText)
        )
        clickRecognizer.numberOfClicksRequired = 1
        textView.addGestureRecognizer(clickRecognizer)

        speechButton.imagePosition = .imageOnly
        speechButton.isBordered = false
        speechButton.focusRingType = .none
        speechButton.contentTintColor = NSColor.white.withAlphaComponent(0.82)
        speechButton.target = self
        speechButton.action = #selector(speakDisplayedText)
        setSpeechState(.idle)

        dragHandle.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: "拖动气泡"
        )
        dragHandle.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 6,
            weight: .semibold
        )
        dragHandle.contentTintColor = NSColor.white.withAlphaComponent(0.62)
        dragHandle.imageScaling = .scaleProportionallyDown
        dragHandle.toolTip = "拖动气泡"

        scrollView.documentView = textView
        addSubview(scrollView)
        addSubview(speechButton)
        addSubview(dragHandle)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? SelectionPanel {
            panel.performBubbleDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    func setText(_ text: String) {
        guard textView.string != text else { return }
        displayedText = text

        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: SelectionResultTextStyle.attributes
            )
        )
        scrollView.contentView.scroll(to: .zero)
        needsLayout = true
    }

    func setSpeechState(_ state: SpeechPlaybackState) {
        let symbolName: String
        let label: String
        switch state {
        case .idle:
            symbolName = "speaker.wave.2"
            label = "朗读结果"
        case .playing:
            symbolName = "pause.fill"
            label = "暂停朗读"
        case .paused:
            symbolName = "play.fill"
            label = "继续朗读"
        }
        speechButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )
        speechButton.toolTip = label
        speechButton.setAccessibilityLabel(label)
    }

    @objc private func copyDisplayedText() {
        guard !displayedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedText, forType: .string)
    }

    @objc private func speakDisplayedText() {
        guard !displayedText.isEmpty else { return }
        speakHandler?()
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return 0
        }

        let containerWidth = max(
            1,
            width - (textView.textContainerInset.width * 2)
        )
        if textContainer.containerSize.width != containerWidth {
            textContainer.containerSize = NSSize(
                width: containerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
            let exclusionWidth = SelectionResultTextStyle.firstLineAccessoryWidth
            textContainer.exclusionPaths = [
                NSBezierPath(
                    rect: NSRect(
                        x: max(0, containerWidth - exclusionWidth),
                        y: 0,
                        width: exclusionWidth,
                        height: SelectionResultTextStyle.firstLineAccessoryHeight
                    )
                )
            ]
            layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count),
                actualCharacterRange: nil
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        let minimumHeight = ceil(
            layoutManager.defaultLineHeight(for: SelectionResultTextStyle.font)
        ) + (textView.textContainerInset.height * 2)
        return max(
            minimumHeight,
            ceil(layoutManager.usedRect(for: textContainer).maxY)
                + (textView.textContainerInset.height * 2)
        )
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        dragHandle.frame = NSRect(
            x: bounds.maxX - SelectionResultTextStyle.dragHandleSize.width,
            y: bounds.maxY - SelectionResultTextStyle.dragHandleSize.height,
            width: SelectionResultTextStyle.dragHandleSize.width,
            height: SelectionResultTextStyle.dragHandleSize.height
        )
        speechButton.frame = NSRect(
            x: dragHandle.frame.minX - SelectionResultTextStyle.speechButtonSize.width,
            y: bounds.maxY - SelectionResultTextStyle.speechButtonSize.height,
            width: SelectionResultTextStyle.speechButtonSize.width,
            height: SelectionResultTextStyle.speechButtonSize.height
        )

        let documentWidth = max(1, bounds.width)
        let textHeight = measuredHeight(for: documentWidth)
        let isScrollable = textHeight > bounds.height + 0.5
        scrollView.hasVerticalScroller = isScrollable
        scrollView.verticalScrollElasticity = isScrollable ? .automatic : .none

        let documentSize = NSSize(
            width: documentWidth,
            height: max(bounds.height, textHeight)
        )
        textView.maxSize = NSSize(
            width: documentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        if textView.frame.origin != .zero {
            textView.setFrameOrigin(.zero)
        }
        if textView.frame.size != documentSize {
            textView.setFrameSize(documentSize)
        }

        var scrollOrigin = scrollView.contentView.bounds.origin
        scrollOrigin.x = 0
        if !isScrollable {
            scrollOrigin.y = 0
        }
        if scrollView.contentView.bounds.origin != scrollOrigin {
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

@MainActor
private final class SelectionPanel: NSPanel {
    var mouseDownHandler: (() -> Void)?
    var mouseUpHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            mouseDownHandler?()
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            mouseUpHandler?()
        }
    }

    func performBubbleDrag(with event: NSEvent) {
        performDrag(with: event)
        mouseUpHandler?()
    }
}

@MainActor
private final class SelectionHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? SelectionPanel {
            panel.performBubbleDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
private final class SelectionBubbleController {
    private let panel: NSPanel
    private let model: SelectionBubbleModel
    private let compactView: SelectionHostingView<SelectionBubbleView>
    private let resultView: SelectionBubbleResultView
    private var cancellable: AnyCancellable?
    private var speechCancellable: AnyCancellable?
    private var anchor = NSPoint.zero
    private var interactionInProgress = false
    private var interactionEndTask: Task<Void, Never>?

    var isInteracting: Bool {
        interactionInProgress
    }

    var isVisible: Bool {
        panel.isVisible
    }

    init(state: AppState) {
        let model = SelectionBubbleModel(state: state)
        self.model = model
        compactView = SelectionHostingView(rootView: SelectionBubbleView(model: model))
        resultView = SelectionBubbleResultView(frame: .zero)
        resultView.speakHandler = { [weak model] in
            model?.speakResult()
        }
        panel = SelectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 48, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.ignoresMouseEvents = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = compactView
        if let selectionPanel = panel as? SelectionPanel {
            selectionPanel.mouseDownHandler = { [weak self] in
                self?.beginInteraction()
            }
            selectionPanel.mouseUpHandler = { [weak self] in
                self?.updateAnchorFromPanelPosition()
                self?.scheduleEndInteraction()
            }
        }
        cancellable = Publishers.CombineLatest(
            model.$displayText,
            model.$phase
        ).sink { [weak self] text, phase in
            self?.resize(for: text, phase: phase)
        }
        speechCancellable = model.$speechState
            .removeDuplicates()
            .sink { [weak self] speechState in
                self?.resultView.setSpeechState(speechState)
            }
    }

    func show(text: String, near point: NSPoint) {
        anchor = point
        interactionEndTask?.cancel()
        interactionInProgress = false
        model.reset(text: text)
        resize(for: model.displayText, phase: model.phase)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
    }

    func hide() {
        interactionEndTask?.cancel()
        interactionInProgress = false
        model.cancel()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func contains(event: NSEvent) -> Bool {
        guard panel.isVisible else { return false }
        if event.window === panel || event.windowNumber == panel.windowNumber {
            return true
        }
        return contains(screenPoint: NSEvent.mouseLocation)
    }

    func contains(screenPoint: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    func beginInteraction() {
        interactionEndTask?.cancel()
        interactionInProgress = true
    }

    func scheduleEndInteraction() {
        interactionEndTask?.cancel()
        interactionEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            self?.interactionInProgress = false
        }
    }

    private func updateAnchorFromPanelPosition() {
        anchor = NSPoint(
            x: panel.frame.minX - 5,
            y: panel.frame.minY - 5
        )
    }

    private func resize(
        for text: String,
        phase: SelectionBubbleModel.Phase
    ) {
        let font = SelectionResultTextStyle.font
        let attributes = SelectionResultTextStyle.attributes
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let resultMaxWidth = min(400, max(80, visible.width - 8))
        let compactMaxWidth = min(200, max(80, visible.width - 8))
        let maxHeight = min(300, max(80, visible.height - 8))
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        let width: CGFloat
        let height: CGFloat
        let contentView: NSView
        if phase == .result {
            width = SelectionResultTextStyle.bubbleWidth(
                for: text,
                maximumWidth: resultMaxWidth
            )
            resultView.setText(text)
            height = min(maxHeight, resultView.measuredHeight(for: width))
            contentView = resultView
        } else {
            width = min(
                compactMaxWidth,
                max(26, ceil((text as NSString).size(withAttributes: attributes).width) + 8)
            )
            height = max(16, lineHeight + 4)
            contentView = compactView
        }
        if panel.contentView !== contentView {
            panel.contentView = contentView
        }
        panel.setContentSize(NSSize(width: width, height: height))
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()

        var origin = NSPoint(x: anchor.x + 5, y: anchor.y + 5)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - height - 4)
        panel.setFrameOrigin(origin)
    }
}
