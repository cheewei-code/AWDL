import Cocoa
import ServiceManagement

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private let awdlManager = AWDLManager()

    // MARK: - Menu bar

    private var statusItem: NSStatusItem!

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestAuthorization()

        setupStatusItem()
        wireCallbacks()
        updateMenuBar()
        awdlManager.startMonitoring()
        ensurePrivilegedAccess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        awdlManager.stopMonitoring()
    }

    // MARK: - Privileged access

    /// Installs the passwordless sudoers rule on first launch (one-time password prompt).
    private func ensurePrivilegedAccess() {
        guard !awdlManager.isSudoersRuleInstalled() else { return }
        awdlManager.installSudoersRule { success in
            NSLog("AppDelegate: sudoers rule setup %@", success ? "succeeded" : "failed")
        }
    }

    // MARK: - Status item setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.menuBarFont(ofSize: 0)
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        // Clear so right-click doesn't reuse stale menu later
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    // MARK: - Callbacks

    private func wireCallbacks() {
        awdlManager.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.updateMenuBar() }
        }
    }

    // MARK: - Menu bar title

    private func updateMenuBar() {
        statusItem.button?.title = awdlManager.isAWDLActive() ? "AWDL ●" : "AWDL ○"
    }

    // MARK: - Menu construction

    /// Builds a fresh menu every time it opens so all states are current.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let isActive = awdlManager.isAWDLActive()

        // --- Status label (non-clickable) ---
        let status: String
        if isActive {
            status = "Active"
        } else if awdlManager.userManuallyDisabledAWDL {
            status = "Inactive (kept off)"
        } else {
            status = "Inactive"
        }
        menu.addItem(infoItem("Status: \(status)"))
        menu.addItem(.separator())

        // --- Toggle action ---
        if isActive {
            menu.addItem(makeItem("Disable AWDL", action: #selector(toggleAWDL), tag: 0))
        } else {
            menu.addItem(makeItem("Enable AWDL",  action: #selector(toggleAWDL), tag: 1))
        }
        menu.addItem(.separator())

        // --- Launch at Login ---
        let loginItem = makeItem("Launch at Login", action: #selector(toggleLaunchAtLogin))
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", action: #selector(quit)))

        return menu
    }

    /// Creates a non-clickable label item.
    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Creates a standard clickable menu item targeting self.
    private func makeItem(
        _ title: String,
        action: Selector,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag    = tag
        return item
    }

    // MARK: - Menu actions

    @objc private func toggleAWDL(_ sender: NSMenuItem) {
        let enabling = sender.tag == 1   // tag 1 = "Enable AWDL"

        if enabling {
            awdlManager.enableAWDL { success in
                guard success else { return }
                NotificationManager.shared.send(title: "AWDL Enabled", body: "AWDL turned on.")
            }
        } else {
            awdlManager.disableAWDL { success in
                guard success else { return }
                NotificationManager.shared.send(
                    title: "AWDL Disabled",
                    body: "AWDL turned off. It will be kept off until you enable it again."
                )
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at Login (SMAppService, macOS 13+)

    @objc private func toggleLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if isLaunchAtLoginEnabled() {
                    try service.unregister()
                } else {
                    try service.register()
                }
            } catch {
                NSLog("AppDelegate: SMAppService error — %@", error.localizedDescription)
            }
        } else {
            NSLog("AppDelegate: Launch at Login requires macOS 13+")
        }
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
}
