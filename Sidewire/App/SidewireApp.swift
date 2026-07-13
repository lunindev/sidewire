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
        .defaultSize(width: 760, height: 520)
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
        MainActor.assumeIsolated { AppSettings.shared.applyActivationPolicy() }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
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
                SourceView(controller: source)
            } else if let display = model.display {
                DisplayView(controller: display)
            } else {
                RolePickerView()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        // Stash the window opener so non-View code (a menu-bar-only DisplayController) can
        // resurface this window when a Source connects. Captured while the window is alive.
        .onAppear { MainWindowOpener.open = { openWindow(id: "main") } }
    }
}
