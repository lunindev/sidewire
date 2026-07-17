import SwiftUI

// Not @main: the entry point is main.swift, which routes `--vd-helper` to the
// virtual-display helper before starting the app.
struct SidewireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    // Phase 9 — Sparkle 2 auto-update. Held for the app's lifetime so the background scheduler
    // and the "Check for Updates…" command share one updater.
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        Window("Sidewire", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 820, height: 700)
        // Without this the window keeps whatever size it was given and simply clips content that
        // doesn't fit — SwiftUI centres the overflowing column, so the TOP of the screen (the
        // status header, Cancel, Switch role) renders at a negative y and is never drawn at all.
        // That is not theoretical: it is why the app looked like it had no Cancel button.
        .windowResizability(.contentMinSize)
        .commands {
            // The canonical Sparkle-SwiftUI menu action, placed under the app menu's About item.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            // D8 — re-show the first-run Welcome from the Help menu.
            CommandGroup(replacing: .help) {
                Button("Show Welcome…") {
                    NotificationCenter.default.post(name: .sidewireShowWelcome, object: nil)
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(updater)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
    }
}

/// The menu-bar status icon. Reflects connection state (filled when a stream is live) so
/// menu-bar-only users can tell at a glance. Kept a plain template SF Symbol — no color —
/// per menu-bar conventions.
private struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let source = model.source {
            SourceStatusIcon(controller: source)
        } else if let display = model.display {
            DisplayStatusIcon(controller: display)
        } else {
            Image(systemName: "rectangle.on.rectangle")
        }
    }
}

/// Thin observers so the menu-bar icon re-renders when the active role's live @Published
/// `isConnected` flips. Filled symbol = a stream is up.
private struct SourceStatusIcon: View {
    @ObservedObject var controller: SourceController
    var body: some View {
        Image(systemName: controller.isConnected ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
    }
}

private struct DisplayStatusIcon: View {
    @ObservedObject var controller: DisplayController
    var body: some View {
        Image(systemName: controller.isConnected ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
    }
}

/// Bridges non-View code (the DisplayController) to SwiftUI's window opening, which lives only
/// in the environment. RootView stashes the action on appear so a menu-bar-only Display can
/// surface the window when a Source connects into an otherwise windowless app.
@MainActor
enum MainWindowOpener {
    static var open: (() -> Void)?
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        open?()
    }
}

/// Applies the Dock-presence preference before any window shows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppSettings.shared.applyActivationPolicy()
            // Pin the permission snapshot to the real process start. It's a lazy static, so if the
            // first thing to read it were the setup gate, a Mac that launched as the extra screen
            // would sample it only when switched to be the main Mac — by which time a permission
            // granted meanwhile would look like it had always been there, and the restart it still
            // needs would be skipped silently.
            PermissionsModel.primeLaunchSnapshot()
        }
    }

    /// On quit, send the peer a graceful BYE before the process dies, then hold termination
    /// briefly so it flushes over TCP. Without this, ⌘Q just drops the socket (a clean, "nil"
    /// close the peer reads as transient) and the other Mac keeps its virtual display and tries
    /// to reconnect — leaving a phantom desktop the cursor could slide onto.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let needsFlush = MainActor.assumeIsolated { AppModel.shared?.prepareForTermination() ?? false }
        guard needsFlush else { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var permissions = PermissionsModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !settings.hasSeenWelcome || model.showWelcomeAgain {
                WelcomeView {
                    settings.hasSeenWelcome = true
                    model.showWelcomeAgain = false // D8: clear the transient re-show
                }
            } else if model.role == nil {
                RolePickerView()
            } else if let source = model.source {
                // Permissions are a GATE, not a banner: until this Mac can record a screen and
                // accept remote input there is nothing useful to do on the connect screen, and
                // showing both at once is what made it read as a debug panel.
                //
                // It gates the way IN only. A revoke mid-session must not yank a live stream off
                // screen and replace it with a setup page that has no Disconnect — SourceView's
                // accessibilityBanner was written for exactly that case and owns it.
                if permissions.isReady || source.isConnected || source.isConnecting {
                    SourceView(controller: source)
                } else {
                    PermissionsGateView(model: permissions) { model.switchRole() }
                }
            } else if let display = model.display {
                // The extra screen needs neither permission — it only decodes and shows.
                DisplayView(controller: display)
            } else {
                RolePickerView()
            }
        }
        // The floor has to clear the tallest screen that can't scroll. It's belt-and-braces with
        // the ScrollViews inside RolePicker/Welcome — those are what stop this constant from
        // silently rotting the next time someone adds a line of copy.
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            // Stash the window opener so non-View code (a menu-bar-only DisplayController) can
            // resurface this window when a Source connects. Captured while the window is alive.
            MainWindowOpener.open = { openWindow(id: "main") }
        }
        // Poll only where the answer can change what's on screen. The extra-screen role needs
        // neither permission, and nothing reads this model outside the Main Mac's branch.
        // `initial: true` covers the launch case, which .onAppear alone would; .onChange is what
        // re-arms it across a role switch, which .onAppear would not.
        .onChange(of: model.role, initial: true) { _, role in
            if role == .source { permissions.start() } else { permissions.stop() }
        }
        .onDisappear { permissions.stop() }
    }
}
