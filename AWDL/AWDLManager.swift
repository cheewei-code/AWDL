import Foundation
import AppKit

// MARK: - AWDLManager
// Responsible for:
//   • Reading current AWDL state via `ifconfig awdl0`
//   • Enabling/disabling AWDL via NSAppleScript with administrator privileges
//   • Persisting user intent flags in UserDefaults

final class AWDLManager {

    // MARK: UserDefaults keys

    private enum Keys {
        static let userManuallyDisabledAWDL = "userManuallyDisabledAWDL"
        static let autoManageGameMode       = "autoManageGameMode"
    }

    // MARK: Stored state

    /// True if the user explicitly turned AWDL off via the menu.
    /// Not set when Game Mode disables AWDL automatically.
    var userManuallyDisabledAWDL: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.userManuallyDisabledAWDL) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.userManuallyDisabledAWDL) }
    }

    /// Whether AWDL should be automatically managed when Game Mode changes state.
    /// Defaults to true on first launch.
    var autoManageGameMode: Bool {
        get {
            // Default to true if key has never been written
            if UserDefaults.standard.object(forKey: Keys.autoManageGameMode) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Keys.autoManageGameMode)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoManageGameMode) }
    }

    // MARK: Callback

    /// Called after any AWDL state change (successful or not) so the menu bar can refresh.
    var onStateChange: (() -> Void)?

    // MARK: - State reading

    /// Returns true if awdl0 exists and reports "status: active".
    /// Returns false if the interface is down or doesn't exist.
    func isAWDLActive() -> Bool {
        let result = shell("ifconfig awdl0 2>/dev/null")
        // `ifconfig awdl0` outputs "status: active" when the interface is up
        return result.contains("status: active")
    }

    /// Returns true if the awdl0 interface exists at all (some Macs may lack it).
    func awdlInterfaceExists() -> Bool {
        let result = shell("ifconfig awdl0 2>&1")
        // "ifconfig: interface awdl0 does not exist" → interface absent
        return !result.contains("does not exist") && !result.isEmpty
    }

    // MARK: - AWDL control

    /// Enables AWDL. Runs `ifconfig awdl0 up` with admin privileges via AppleScript.
    /// - Parameter isManual: If true, clears the userManuallyDisabledAWDL flag.
    func enableAWDL(isManual: Bool = false) {
        guard awdlInterfaceExists() else {
            NSLog("AWDLManager: awdl0 interface not found, skipping enable")
            return
        }
        runPrivileged(command: "ifconfig awdl0 up") { [weak self] success in
            if success && isManual {
                self?.userManuallyDisabledAWDL = false
            }
            self?.onStateChange?()
        }
    }

    /// Disables AWDL. Runs `ifconfig awdl0 down` with admin privileges via AppleScript.
    /// - Parameter isManual: If true, sets userManuallyDisabledAWDL = true.
    func disableAWDL(isManual: Bool = false) {
        guard awdlInterfaceExists() else {
            NSLog("AWDLManager: awdl0 interface not found, skipping disable")
            return
        }
        runPrivileged(command: "ifconfig awdl0 down") { [weak self] success in
            if success && isManual {
                self?.userManuallyDisabledAWDL = true
            }
            self?.onStateChange?()
        }
    }

    // MARK: - One-time privileged setup

    private let sudoersPath = "/etc/sudoers.d/awdl"

    /// Returns true if the passwordless sudo rule for AWDL is already installed.
    func isSudoersRuleInstalled() -> Bool {
        let result = shell("test -f \(sudoersPath) && echo yes || echo no")
        return result.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    /// Installs a sudoers rule so the current user can run `ifconfig awdl0 up/down`
    /// without a password. Prompts for admin credentials exactly once via AppleScript.
    /// The completion handler is called on the main thread.
    func installSudoersRule(completion: @escaping (Bool) -> Void) {
        let username = NSUserName()
        // Allow only safe characters to prevent any shell injection via username
        let safe = username.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !safe.isEmpty else {
            NSLog("AWDLManager: Unexpected username format, aborting sudoers install")
            completion(false)
            return
        }

        let rule = "\(safe) ALL=(root) NOPASSWD: /sbin/ifconfig awdl0 up, /sbin/ifconfig awdl0 down"
        // Write rule then lock permissions (sudoers files must be 0440)
        let command = "echo '\(rule)' > \(sudoersPath) && chmod 440 \(sudoersPath)"

        DispatchQueue.main.async {
            let script = "do shell script \"\(command)\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error = error {
                NSLog("AWDLManager: sudoers install failed — %@", error.description)
                completion(false)
            } else {
                NSLog("AWDLManager: sudoers rule installed at %@", self.sudoersPath)
                completion(true)
            }
        }
    }

    // MARK: - Private helpers

    /// Runs a privileged shell command via `sudo -n` (non-interactive, no password prompt).
    /// Falls back to the AppleScript password dialog if the sudoers rule is missing.
    /// The completion handler is called on the main thread.
    private func runPrivileged(command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let output = self.shell("sudo -n \(command) 2>&1")
            let success = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if success {
                DispatchQueue.main.async { completion(true) }
            } else {
                // Sudoers rule not yet installed — fall back to AppleScript prompt
                NSLog("AWDLManager: sudo -n failed (%@), falling back to AppleScript", output)
                self.runPrivilegedViaAppleScript(command: command, completion: completion)
            }
        }
    }

    /// Last-resort AppleScript escalation (shows password dialog).
    private func runPrivilegedViaAppleScript(command: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let script = "do shell script \"\(command)\" with administrator privileges"
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error = error {
                NSLog("AWDLManager: AppleScript error — %@", error.description)
                completion(false)
            } else {
                completion(true)
            }
        }
    }

    /// Synchronous shell helper for read-only queries (ifconfig, defaults read).
    /// Not used for privileged writes.
    @discardableResult
    private func shell(_ command: String) -> String {
        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            NSLog("AWDLManager: shell error — %@", error.localizedDescription)
            return ""
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
