import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: MainPanelController?
    private var selectionController: SelectionTranslationController?
    private var hotKeyManager: HotKeyManager?
    private var cancellables = Set<AnyCancellable>()
    private var selectionMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        panelController = MainPanelController(state: state)
        selectionController = SelectionTranslationController(state: state)
        hotKeyManager = HotKeyManager { [weak self] in
            self?.panelController?.toggle()
        }
        configureStatusItem()

        state.settings.$selectionEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.selectionMenuItem?.state = enabled ? .on : .off
                if enabled {
                    self?.selectionController?.start()
                } else {
                    self?.selectionController?.stop()
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        selectionController?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateAccessibilityStatus()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "character.bubble",
                accessibilityDescription: "Trans"
            )
            if let image = image {
                button.image = image
            } else {
                button.title = "译"
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        let openItem = NSMenuItem(
            title: "打开翻译",
            action: #selector(openTranslation),
            keyEquivalent: ""
        )
        openItem.target = self
        let shortcutItem = NSMenuItem(title: "快捷键  ⌃⌥Space", action: nil, keyEquivalent: "")
        shortcutItem.isEnabled = false
        let selectionItem = NSMenuItem(
            title: "划词翻译",
            action: #selector(toggleSelectionTranslation),
            keyEquivalent: ""
        )
        selectionItem.target = self
        selectionItem.state = state?.settings.selectionEnabled == true ? .on : .off
        selectionMenuItem = selectionItem
        let permissionItem = NSMenuItem(
            title: "辅助功能权限：检查中",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        accessibilityMenuItem = permissionItem
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        let quitItem = NSMenuItem(
            title: "退出 Trans",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        menu.addItem(openItem)
        menu.addItem(shortcutItem)
        menu.addItem(.separator())
        menu.addItem(selectionItem)
        menu.addItem(permissionItem)
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
        updateAccessibilityStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateAccessibilityStatus()
    }

    @objc private func openTranslation() {
        panelController?.show()
    }

    @objc private func openSettings() {
        panelController?.show(settings: true)
    }

    @objc private func toggleSelectionTranslation() {
        guard let settings = state?.settings else { return }
        settings.selectionEnabled.toggle()
        settings.save()
    }

    @objc private func openAccessibilitySettings() {
        state?.settings.openAccessibilitySettings()
        updateAccessibilityStatus()
    }

    private func updateAccessibilityStatus() {
        guard let settings = state?.settings else { return }
        settings.refreshSystemPermissions()
        let accessibilityTrusted = settings.accessibilityTrusted
        accessibilityMenuItem?.title = accessibilityTrusted
            ? "辅助功能权限：已授权"
            : "辅助功能权限：需要授权…"
        accessibilityMenuItem?.state = accessibilityTrusted ? .on : .off
        accessibilityMenuItem?.isEnabled = !accessibilityTrusted
        if accessibilityTrusted && settings.selectionEnabled {
            selectionController?.start()
        } else {
            selectionController?.stop()
        }
    }
}
