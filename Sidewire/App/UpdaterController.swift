import Foundation
import Combine
import Sparkle

/// Wraps Sparkle 2's `SPUStandardUpdaterController` for the SwiftUI app — the standard
/// Sparkle-in-SwiftUI pattern (a `@StateObject` held by `SidewireApp`, a "Check for Updates…"
/// menu command, and an opt-in automatic-check toggle).
///
/// Sparkle is the app's **first and only** network "phone-home": it fetches an EdDSA-signed
/// appcast from GitHub Releases to see if a newer signed build exists. Everything else in
/// Sidewire is 100% local — no accounts, no telemetry, no HTTP anywhere else. Until the owner
/// sets a real `SUPublicEDKey` in Info.plist (via Sparkle's `generate_keys`), Sparkle **fails
/// closed**: it refuses any update it can't verify against that public key, which is the safe
/// default.
@MainActor
final class UpdaterController: ObservableObject {
    /// Mirrors the updater's own `canCheckForUpdates` (false while a check/install is already
    /// in flight). Bound to the "Check for Updates…" command's `.disabled(!…)`.
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    /// The underlying Sparkle updater. `checkForUpdates()` / `automaticallyChecksForUpdates`
    /// go through here.
    var updater: SPUUpdater { controller.updater }

    init() {
        // startingUpdater: true → Sparkle starts its scheduler now. Whether it checks in the
        // background is still gated by the user's preference (SUEnableAutomaticChecks defaults
        // to false in Info.plist — opt-in). nil delegates: default behavior + standard UI.
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        // `canCheckForUpdates` is KVO-observable (documented Sparkle-SwiftUI pattern).
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    /// The canonical Sparkle-SwiftUI menu action (from the "Check for Updates…" command).
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    /// Backs the Settings "Automatically check for updates" toggle. Sparkle persists this in
    /// its own defaults; `SUEnableAutomaticChecks` (Info.plist, false) supplies the first-run
    /// default. `objectWillChange` so the toggle reflects the write immediately.
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }
}
