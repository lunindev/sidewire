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
    /// in flight). Bound to the "Check for Updates…" command's `.disabled(!…)`. Stays false
    /// while the updater is unconfigured (see `isConfigured`).
    @Published var canCheckForUpdates = false

    /// True once the owner has set a real appcast feed + EdDSA public key in Info.plist. Until
    /// then the updater is left dormant (see below) and the update UI is disabled/hidden.
    let isConfigured: Bool

    private let controller: SPUStandardUpdaterController

    /// The underlying Sparkle updater. `checkForUpdates()` / `automaticallyChecksForUpdates`
    /// go through here.
    var updater: SPUUpdater { controller.updater }

    init() {
        let configured = Self.updatesConfigured()
        isConfigured = configured
        // Only *start* Sparkle when the config is real. With the placeholder SUPublicEDKey and
        // the "OWNER" feed URL that ship in the repo, `startUpdater()` fails and Sparkle pops
        // its "The updater failed to start" alert at launch (this is what appeared on the client
        // Mac). So when unconfigured we build the controller dormant (startingUpdater: false) and
        // never start it: no scheduler, no network, no alert. `canCheckForUpdates` then stays
        // false, disabling the menu item. When the owner fills in a real key + feed URL (docs/12
        // B.3), this starts normally. Background checks remain opt-in via SUEnableAutomaticChecks.
        controller = SPUStandardUpdaterController(
            startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: nil)
        if configured {
            // `canCheckForUpdates` is KVO-observable (documented Sparkle-SwiftUI pattern).
            updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        } else {
            Log.app.notice("Sparkle auto-update disabled: SUPublicEDKey/SUFeedURL are still placeholders (owner-gated — see docs/12 §B.3)")
        }
    }

    /// The canonical Sparkle-SwiftUI menu action (from the "Check for Updates…" command). A no-op
    /// while unconfigured — though the command is also `.disabled(!canCheckForUpdates)`.
    func checkForUpdates() {
        guard isConfigured else { return }
        updater.checkForUpdates()
    }

    /// Backs the Settings "Automatically check for updates" toggle. Sparkle persists this in
    /// its own defaults; `SUEnableAutomaticChecks` (Info.plist, false) supplies the first-run
    /// default. `objectWillChange` so the toggle reflects the write immediately. Inert while
    /// unconfigured (the dormant updater has no scheduler to enable).
    var automaticallyChecksForUpdates: Bool {
        get { isConfigured ? updater.automaticallyChecksForUpdates : false }
        set {
            guard isConfigured else { return }
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Real config = a non-placeholder EdDSA public key AND a feed URL without the "OWNER"
    /// placeholder (mirrors the two owner-gated fields in Info.plist / docs/12 §B.3).
    private static func updatesConfigured() -> Bool {
        let info = Bundle.main.infoDictionary
        let key = (info?["SUPublicEDKey"] as? String) ?? ""
        let feed = (info?["SUFeedURL"] as? String) ?? ""
        // The key must be a real Ed25519 public key: base64 that decodes to exactly 32 bytes. This
        // rejects the shipped "REPLACE_WITH…" placeholder AND an owner-entered key that's
        // truncated/typo'd (wrong length / not valid base64) — either would let startUpdater() run
        // and pop Sparkle's "The updater failed to start" alert. (An empty key decodes to 0 bytes,
        // so the length check also covers the missing-key case.)
        let keyOK = !key.hasPrefix("REPLACE_WITH") && (Data(base64Encoded: key)?.count == 32)
        // Treat the feed as unconfigured only when it still contains the exact shipped placeholder
        // path ("github.com/OWNER/", from Info.plist) — not merely the substring "OWNER", which
        // could legitimately appear in a real org/repo name.
        let feedOK = !feed.isEmpty && !feed.contains("github.com/OWNER/")
        return keyOK && feedOK
    }
}
