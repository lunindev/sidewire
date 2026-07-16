import Foundation
import SwiftUI
import SidewireProtocol

extension Notification.Name {
    /// Posted by the Settings pane / Help menu to re-present the Welcome screen (D8).
    static let sidewireShowWelcome = Notification.Name("sidewire.showWelcome")
    /// Posted when the trust store changes (a new Mac paired, or one was forgotten) so the
    /// "Paired Macs" settings section can refresh.
    static let sidewirePairedPeersChanged = Notification.Name("sidewire.pairedPeersChanged")
}

/// Top-level app state: the chosen role (persisted) and the active role controller.
@MainActor
final class AppModel: ObservableObject {
    /// Weak handle so the AppDelegate can flush a graceful goodbye on ⌘Q (the delegate can't
    /// reach the SwiftUI `@StateObject`). Set in `init`; there is only ever one AppModel.
    static weak var shared: AppModel?

    @Published var role: Role?
    @Published private(set) var source: SourceController?
    @Published private(set) var display: DisplayController?
    /// D8 — transient (not persisted): drives a re-show of the Welcome screen over the current
    /// view. Set true by the Settings/Help "Show Welcome…" action; cleared when dismissed.
    @Published var showWelcomeAgain = false

    private let roleKey = "sidewire.role"
    private var welcomeObserver: Any?

    init() {
        AppModel.shared = self
        // D8 — let the Settings pane / Help menu re-present Welcome without a direct reference.
        welcomeObserver = NotificationCenter.default.addObserver(
            forName: .sidewireShowWelcome, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showWelcomeAgain = true
                MainWindowOpener.show() // surface the window in menu-bar-only mode
            }
        }
        if let raw = UserDefaults.standard.string(forKey: roleKey), let r = Role(rawValue: raw) {
            // A returning user (already picked a role before this build) is not first-run —
            // skip the Welcome so it can't sit on top of a live, already-started controller.
            if !AppSettings.shared.hasSeenWelcome { AppSettings.shared.hasSeenWelcome = true }
            activate(r)
        }
    }

    deinit {
        if let welcomeObserver { NotificationCenter.default.removeObserver(welcomeObserver) }
    }

    func setRole(_ role: Role) {
        UserDefaults.standard.set(role.rawValue, forKey: roleKey)
        activate(role)
    }

    /// Called from the AppDelegate as the app quits (⌘Q / Quit). Sends a graceful BYE to the
    /// connected peer so it tears down immediately — a fatal "user" reason means the other Mac
    /// destroys its virtual display at once instead of waiting for the heartbeat watchdog and
    /// then reconnecting to a Mac that's gone (which left a phantom desktop the cursor strayed
    /// onto). Returns true if a live link existed, so the caller can briefly defer termination to
    /// let the BYE flush over the wire.
    @discardableResult
    func prepareForTermination() -> Bool {
        let live = (source?.isConnected ?? false) || (display?.isConnected ?? false)
        source?.disconnect() // sends BYE("user") + destroys this Mac's own virtual display
        display?.stop()      // sends BYE("user")
        return live
    }

    func switchRole() {
        source?.disconnect()
        source?.stopDiscovery() // also cancels the browser + the empty-state escalation timer
        display?.stop()
        source = nil
        display = nil
        role = nil
        UserDefaults.standard.removeObject(forKey: roleKey)
    }

    private func activate(_ role: Role) {
        self.role = role
        switch role {
        case .source:
            let c = SourceController()
            source = c
            display = nil
            c.startDiscovery()
            // Don't auto-connect a Mac that can't capture or inject yet: the setup gate is on
            // screen, so the user would never see the stream fail — they'd just see a virtual
            // display appear for no reason. Granting requires a relaunch, and this runs again on
            // the next launch with the permissions in place.
            if Permissions.hasScreenRecording, Permissions.hasAccessibility { c.maybeAutoConnect() }
        case .display:
            let d = DisplayController()
            display = d
            source = nil
            d.start()
        }
    }
}
