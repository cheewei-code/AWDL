import Cocoa
import ServiceManagement

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private let awdlManager      = AWDLManager()
    private let gameModeObserver = GameModeObserver()

    // MARK: - Menu bar

    private var statusItem: NSStatusItem!

    // Tracks whether the last AWDL-off event was caused by Game Mode (not the user).
    // Not persisted — resets on relaunch; that's intentional.
    private var gameModeDidDisableAWDL = false

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestAuthorization()

        setupStatusItem()
        wireCallbacks()
        gameModeObserver.start()
        updateMenuBar()
        ensurePrivilegedAccess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        gameModeObserver.stop()
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

        gameModeObserver.onGameModeChange = { [weak self] isActive in
            guard let self else { return }
            if isActive {
                self.handleGameModeActivated()
            } else {
                self.handleGameModeDeactivated()
            }
            self.updateMenuBar()
        }
    }

    // MARK: - Game Mode logic

    private func handleGameModeActivated() {
        guard awdlManager.autoManageGameMode else { return }

        // Only disable if AWDL is currently on
        if awdlManager.isAWDLActive() {
            gameModeDidDisableAWDL = true
            // Do NOT set userManuallyDisabledAWDL — this is automated
            awdlManager.disableAWDL(isManual: false)
            NotificationManager.shared.send(
                title: "AWDL Disabled",
                body: "Game Mode activated — AWDL has been turned off."
            )
        }
    }

    private func handleGameModeDeactivated() {
        guard awdlManager.autoManageGameMode else {
            gameModeDidDisableAWDL = false
            return
        }

        // Re-enable only if we were the ones who turned it off, and the user
        // didn't also manually disable it in the interim.
        if gameModeDidDisableAWDL && !awdlManager.userManuallyDisabledAWDL {
            gameModeDidDisableAWDL = false
            awdlManager.enableAWDL(isManual: false)
            NotificationManager.shared.send(
                title: "AWDL Re-enabled",
                body: "Game Mode ended — AWDL has been turned back on."
            )
        } else {
            gameModeDidDisableAWDL = false
        }
    }

    // MARK: - Menu bar title

    private func updateMenuBar() {
        let isActive   = awdlManager.isAWDLActive()
        let isGameMode = gameModeObserver.isGameModeActive

        let title: String
        if isActive {
            title = "AWDL ●"
        } else if isGameMode && awdlManager.autoManageGameMode {
            title = "AWDL ○ 🎮"
        } else {
            title = "AWDL ○"
        }

        statusItem.button?.title = title
    }

    // MARK: - Menu construction

    /// Builds a fresh menu every time it opens so all states are current.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let isActive   = awdlManager.isAWDLActive()
        let isGameMode = gameModeObserver.isGameModeActive

        // --- Status labels (non-clickable) ---
        menu.addItem(infoItem("Status: \(isActive ? "Active" : "Inactive")"))
        menu.addItem(infoItem("Game Mode: \(isGameMode ? "On" : "Off")"))
        menu.addItem(.separator())

        // --- Toggle action ---
        if isActive {
            menu.addItem(makeItem("Disable AWDL", action: #selector(toggleAWDL), tag: 0))
        } else {
            menu.addItem(makeItem("Enable AWDL",  action: #selector(toggleAWDL), tag: 1))
        }
        menu.addItem(.separator())

        // --- Auto-manage toggle ---
        let autoItem = makeItem("Auto-manage with Game Mode", action: #selector(toggleAutoManage))
        autoItem.state = awdlManager.autoManageGameMode ? .on : .off
        menu.addItem(autoItem)

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
            awdlManager.enableAWDL(isManual: true)
            NotificationManager.shared.send(title: "AWDL Enabled", body: "AWDL turned on manually.")
        } else {
            awdlManager.disableAWDL(isManual: true)
            NotificationManager.shared.send(title: "AWDL Disabled", body: "AWDL turned off manually.")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func toggleAutoManage() {
        awdlManager.autoManageGameMode.toggle()
        updateMenuBar()
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
