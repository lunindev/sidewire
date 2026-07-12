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
    @Published var role: Role?
    @Published private(set) var source: SourceController?
    @Published private(set) var display: DisplayController?
    /// D8 — transient (not persisted): drives a re-show of the Welcome screen over the current
    /// view. Set true by the Settings/Help "Show Welcome…" action; cleared when dismissed.
    @Published var showWelcomeAgain = false

    private let roleKey = "sidewire.role"
    private var welcomeObserver: Any?

    init() {
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

    func switchRole() {
        source?.disconnect()
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
            c.maybeAutoConnect()
        case .display:
            let d = DisplayController()
            display = d
            source = nil
            d.start()
        }
    }
}
