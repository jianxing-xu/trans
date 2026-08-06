import AppKit
import SwiftUI

@MainActor
final class MainPanelController: NSWindowController, NSWindowDelegate {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Trans"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 760, height: 500)
        panel.contentView = NSHostingView(rootView: MainPanelView(state: state))
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle() {
        guard let window = window else { return }
        if window.isVisible && window.isKeyWindow {
            state.stopSpeech(for: .mainPanel)
            window.orderOut(nil)
        } else {
            show()
        }
    }

    func show(settings: Bool = false) {
        if settings {
            state.stopSpeech(for: .mainPanel)
        }
        state.showsSettings = settings
        guard let window = window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        state.stopSpeech(for: .mainPanel)
        sender.orderOut(nil)
        return false
    }
}
