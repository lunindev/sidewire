import Foundation
import SwiftUI

/// Live status of the permissions the Main Mac needs. Polls (permissions can be toggled in
/// System Settings while the app runs) so the setup screen updates without a manual refresh.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false

    private var timer: Timer?

    /// What was already granted when this PROCESS started. macOS hands a permission to a running
    /// process lazily — the checkbox flips in System Settings, but frameworks that cached the old
    /// answer keep refusing until the app relaunches. Snapshotting at launch is the only way to
    /// tell "granted and usable" apart from "granted, needs a restart first".
    ///
    /// `static` is load-bearing twice over. This model is a `@StateObject`, which SwiftUI rebuilds
    /// when the window is closed and reopened; an instance property would re-snapshot then and
    /// record a permission granted in the meantime as "had it at launch", silently skipping the
    /// restart it still needs.
    ///
    /// But a Swift `static let` is LAZY — it samples at first access, not at launch. Left to
    /// itself that reintroduces the same bug through a different door: under the extra-screen role
    /// nothing ever reads it, so a user who grants permissions and then switches this Mac to be
    /// the main one would sample "true at launch" and skip the gate forever. `primeLaunchSnapshot()`
    /// is called from the app delegate to pin it to the real process start.
    private static let grantedAtLaunch = (screenRecording: Permissions.hasScreenRecording,
                                          accessibility: Permissions.hasAccessibility)

    /// Sample the launch state now. Must run once at process start, before any window exists —
    /// the value is meaningless if it's first read halfway through a session.
    static func primeLaunchSnapshot() { _ = grantedAtLaunch }

    var allGranted: Bool { screenRecording && accessibility }

    /// True once the user has granted something this process didn't have at launch — on its own
    /// only a statement about *this permission*, never a reason to restart. See `restartRequired`.
    private var grantedSinceLaunch: Bool {
        (!Self.grantedAtLaunch.screenRecording && screenRecording)
            || (!Self.grantedAtLaunch.accessibility && accessibility)
    }

    /// Ask for a restart only once there is nothing left to switch on. Restarting mid-way costs
    /// the user a second restart and — worse — puts a restart button in front of them while a
    /// required permission is still OFF, which is precisely the backwards behaviour this model was
    /// written to eliminate. `allGranted` is the load-bearing half of this predicate.
    var restartRequired: Bool { allGranted && grantedSinceLaunch }

    /// The setup gate is satisfied only when everything is granted AND usable in this process.
    var isReady: Bool { allGranted && !grantedSinceLaunch }

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
