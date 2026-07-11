import SwiftUI

@main
struct SidewireApp: App {
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
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.role == nil {
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
