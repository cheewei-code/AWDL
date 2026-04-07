import Foundation
import CoreFoundation

// MARK: - GameModeObserver
//
// Detects macOS Game Mode state using two strategies in priority order:
//
// 1. PRIMARY — Darwin notification:
//    Observes `com.apple.GameController.gameModeStateChanged` on the Darwin
//    notify center. This is a private/undocumented notification posted by
//    com.apple.gamecontrollerd when Game Mode toggles. No payload is carried;
//    we query the actual state separately after receiving it.
//    ⚠️ Undocumented: may change without notice in future macOS releases.
//
// 2. FALLBACK — 5-second polling:
//    Reads `defaults read com.apple.gamecontrollerd GameModeEnabled` via subprocess.
//    Activated automatically if the Darwin notification has not fired within
//    the first 30 seconds (heuristic to detect unsupported environments).
//    ⚠️ Assumption: the plist key is `GameModeEnabled` (Bool). Verify on OS updates.

final class GameModeObserver {

    // MARK: - Constants

    // Private Darwin notification name posted by gamecontrollerd.
    // Undocumented — verify on each major macOS release.
    private static let gameModeNotificationName = "com.apple.GameController.gameModeStateChanged"

    // Polling interval used by the fallback timer.
    private static let pollInterval: TimeInterval = 5

    // MARK: - State

    private(set) var isGameModeActive: Bool = false

    /// Called on the main thread whenever Game Mode state changes.
    var onGameModeChange: ((Bool) -> Void)?

    private var pollTimer: Timer?
    private var notificationReceived = false   // tracks whether primary method fired

    // MARK: - Lifecycle

    func start() {
        registerDarwinNotification()
        // Schedule a one-shot check: if the Darwin notification hasn't fired
        // within 30 s (e.g. no game has been launched, or the OS dropped support),
        // activate the polling fallback.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            if !self.notificationReceived {
                NSLog("GameModeObserver: Darwin notification not seen in 30s — starting polling fallback")
                self.startPolling()
            }
        }
        // Do an immediate state read regardless of method
        checkAndNotify()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Note: CFNotificationCenter observers are not individually removable
        // without storing the observer token; acceptable for a long-lived singleton.
    }

    // MARK: - Primary: Darwin notification

    private func registerDarwinNotification() {
        // CFNotificationCenter Darwin center delivers notifications posted
        // system-wide by daemons, without needing a Mach port connection.
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = GameModeObserver.gameModeNotificationName as CFString

        // The `observer` pointer is passed back in the callback; we use it to
        // retrieve `self` via an unretained bridge.
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                // This C callback runs on an arbitrary thread; dispatch to main.
                guard let observer else { return }
                let me = Unmanaged<GameModeObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    me.notificationReceived = true
                    me.checkAndNotify()
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    // MARK: - Fallback: polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: GameModeObserver.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkAndNotify()
        }
    }

    // MARK: - State query

    /// Reads the current Game Mode state and fires onGameModeChange if it changed.
    private func checkAndNotify() {
        let active = queryGameModeState()
        guard active != isGameModeActive else { return }
        isGameModeActive = active
        NSLog("GameModeObserver: Game Mode is now %@", active ? "ON" : "OFF")
        onGameModeChange?(active)
    }

    /// Queries Game Mode state via `defaults read com.apple.gamecontrollerd`.
    ///
    /// ⚠️ Assumption: gamecontrollerd stores its state in the plist at
    ///    ~/Library/Preferences/com.apple.gamecontrollerd.plist under key
    ///    `GameModeEnabled` (Bool). Verified on macOS 14. Re-check on 15+.
    ///
    /// Returns false (safe default) if the key is absent or the command fails.
    private func queryGameModeState() -> Bool {
        let result = shell("defaults read com.apple.gamecontrollerd GameModeEnabled 2>/dev/null")
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // `defaults read` returns "1" for true, "0" for false
        return trimmed == "1"
    }

    // MARK: - Shell helper

    @discardableResult
    private func shell(_ command: String) -> String {
        let process = Process()
        process.launchPath = "/bin/zsh"
        process.arguments  = ["-c", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        do {
            try process.run()
        } catch {
            NSLog("GameModeObserver: shell error — %@", error.localizedDescription)
            return ""
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
