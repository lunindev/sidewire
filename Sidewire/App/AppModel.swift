import Foundation
import SwiftUI
import SidewireProtocol

/// Top-level app state: the chosen role (persisted) and the active role controller.
@MainActor
final class AppModel: ObservableObject {
    @Published var role: Role?
    @Published private(set) var source: SourceController?
    @Published private(set) var display: DisplayController?

    private let roleKey = "sidewire.role"

    init() {
        if let raw = UserDefaults.standard.string(forKey: roleKey), let r = Role(rawValue: raw) {
            // A returning user (already picked a role before this build) is not first-run —
            // skip the Welcome so it can't sit on top of a live, already-started controller.
            if !AppSettings.shared.hasSeenWelcome { AppSettings.shared.hasSeenWelcome = true }
            activate(r)
        }
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
