import Foundation
import SwiftUI

/// Live status of the permissions the Source needs. Polls (permissions can be toggled in
/// System Settings while the app runs) so the checklist updates without a manual refresh.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false

    private var timer: Timer?

    var allGranted: Bool { screenRecording && accessibility }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        screenRecording = Permissions.hasScreenRecording
        accessibility = Permissions.hasAccessibility
    }
}
