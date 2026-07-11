import SwiftUI

// Not @main: the entry point is main.swift, which routes `--vd-helper` to the
// virtual-display helper before starting the app.
struct SidewireApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Sidewire", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .defaultSize(width: 760, height: 520)

        MenuBarExtra("Sidewire", systemImage: "rectangle.on.rectangle") {
            MenuBarView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
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

    var body: some View {
        Group {
            if !settings.hasSeenWelcome {
                WelcomeView { settings.hasSeenWelcome = true }
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
    }
}
