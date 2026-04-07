import AppKit

// MARK: - AppObserver
//
// Watches for target applications launching and quitting using NSWorkspace
// notifications. When a watched app opens, onAppActiveChange(true) is called;
// when it quits, onAppActiveChange(false) is called.
//
// No private APIs used — NSWorkspace is fully public.

final class AppObserver {

    // MARK: - Configuration

    /// Bundle identifiers of apps whose launch/quit should be tracked.
    /// Extend this array to watch additional apps.
    static let watchedBundleIDs: Set<String> = [
        "com.nvidia.gfnpc.mall"   // NVIDIA GeForce NOW
    ]

    // MARK: - State

    /// True if any watched app is currently running.
    private(set) var isAppActive: Bool = false

    /// Called on the main thread when the watched-app running state changes.
    var onAppActiveChange: ((Bool) -> Void)?

    // MARK: - Lifecycle

    func start() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Check if a watched app is already running at launch
        checkCurrentState()
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Notification handlers

    @objc private func appLaunched(_ note: Notification) {
        guard isWatchedApp(note) else { return }
        NSLog("AppObserver: watched app launched")
        update(active: true)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard isWatchedApp(note) else { return }
        NSLog("AppObserver: watched app terminated")
        // Re-check in case multiple watched apps are running simultaneously
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkCurrentState()
        }
    }

    // MARK: - Helpers

    private func isWatchedApp(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let id = app?.bundleIdentifier ?? ""
        return Self.watchedBundleIDs.contains(id)
    }

    private func checkCurrentState() {
        let running = NSWorkspace.shared.runningApplications.contains {
            Self.watchedBundleIDs.contains($0.bundleIdentifier ?? "")
        }
        update(active: running)
    }

    private func update(active: Bool) {
        guard active != isAppActive else { return }
        isAppActive = active
        NSLog("AppObserver: watched app is now %@", active ? "running" : "not running")
        onAppActiveChange?(active)
    }
}
