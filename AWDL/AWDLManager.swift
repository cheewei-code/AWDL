import Foundation
import AppKit

// MARK: - AWDLManager
// Responsible for:
//   • Reading current AWDL state via `ifconfig awdl0`
//   • Enabling/disabling AWDL via NSAppleScript with administrator privileges
//   • Persisting user intent flags in UserDefaults
//   • Keeping AWDL off while the user wants it off (macOS re-enables it on its own)

final class AWDLManager {

    // MARK: UserDefaults keys

    private enum Keys {
        static let userManuallyDisabledAWDL = "userManuallyDisabledAWDL"
    }

    // MARK: Stored state

    /// True if the user explicitly turned AWDL off via the menu.
    /// While true, the monitor turns AWDL back off whenever macOS brings it up.
    var userManuallyDisabledAWDL: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.userManuallyDisabledAWDL) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.userManuallyDisabledAWDL) }
    }

    // MARK: Callback

    /// Called after any AWDL state change (successful or not) so the menu bar can refresh.
    /// May be called from a background queue.
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

    /// Enables AWDL. Runs `ifconfig awdl0 up` with admin privileges.
    /// The completion handler is called on the main thread with the result.
    func enableAWDL(completion: ((Bool) -> Void)? = nil) {
        guard awdlInterfaceExists() else {
            NSLog("AWDLManager: awdl0 interface not found, skipping enable")
            completion?(false)
            return
        }
        // Clear the flag before bringing the interface up so the monitor
        // doesn't turn it straight back off.
        userManuallyDisabledAWDL = false
        runPrivileged(command: "ifconfig awdl0 up") { [weak self] success in
            completion?(success)
            self?.onStateChange?()
        }
    }

    /// Disables AWDL. Runs `ifconfig awdl0 down` with admin privileges.
    /// On success, AWDL is kept off until `enableAWDL` is called.
    /// The completion handler is called on the main thread with the result.
    func disableAWDL(completion: ((Bool) -> Void)? = nil) {
        guard awdlInterfaceExists() else {
            NSLog("AWDLManager: awdl0 interface not found, skipping disable")
            completion?(false)
            return
        }
        runPrivileged(command: "ifconfig awdl0 down") { [weak self] success in
            if success {
                self?.userManuallyDisabledAWDL = true
            }
            completion?(success)
            self?.onStateChange?()
        }
    }

    // MARK: - Monitoring

    private let monitorInterval: TimeInterval = 2
    private let monitorQueue = DispatchQueue(label: "com.awdl.AWDLToggle.monitor", qos: .utility)
    private var monitorTimer: DispatchSourceTimer?
    private var lastObservedActive: Bool?
    private var enforcementFailed = false

    /// Starts polling AWDL state. macOS brings awdl0 back up on its own (AirDrop,
    /// AirPlay, Handoff…), so while userManuallyDisabledAWDL is set the monitor
    /// turns it off again. Also fires onStateChange when the state changes externally.
    func startMonitoring() {
        guard monitorTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now(), repeating: monitorInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.monitorTick() }
        timer.resume()
        monitorTimer = timer
    }

    func stopMonitoring() {
        monitorTimer?.cancel()
        monitorTimer = nil
    }

    private func monitorTick() {
        var active = isAWDLActive()

        if active && userManuallyDisabledAWDL {
            // sudo -n only: never show a password dialog from the background.
            if runSudo("ifconfig awdl0 down") {
                NSLog("AWDLManager: AWDL came back up, turned it off again")
                enforcementFailed = false
                active = isAWDLActive()
            } else if !enforcementFailed {
                NSLog("AWDLManager: cannot keep AWDL off — passwordless sudo rule missing")
                enforcementFailed = true
            }
        }

        guard active != lastObservedActive else { return }
        lastObservedActive = active
        onStateChange?()
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
            if self.runSudo(command) {
                DispatchQueue.main.async { completion(true) }
            } else {
                // Sudoers rule not yet installed — fall back to AppleScript prompt
                NSLog("AWDLManager: sudo -n failed, falling back to AppleScript")
                self.runPrivilegedViaAppleScript(command: command, completion: completion)
            }
        }
    }

    /// Runs a command via `sudo -n`. Returns false if sudo would need a password
    /// or the command printed an error.
    private func runSudo(_ command: String) -> Bool {
        let output = shell("sudo -n \(command) 2>&1")
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
