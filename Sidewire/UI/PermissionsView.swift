import SwiftUI

/// The Source's permission checklist. Screen Recording (to capture the virtual display)
/// and Accessibility (to inject the remote keyboard/mouse) are both required, and both
/// need a relaunch after granting — the trap that makes these apps feel broken.
struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: model.allGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.allGranted ? .green : .orange)
                    Text(model.allGranted ? "Permissions granted" : "Finish setup")
                        .font(.headline)
                    Spacer()
                }

                PermissionRow(
                    granted: model.screenRecording,
                    title: "Screen Recording",
                    why: "Lets Sidewire capture the extra display it creates.",
                    action: {
                        _ = Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                    })

                PermissionRow(
                    granted: model.accessibility,
                    title: "Accessibility (Input Control)",
                    why: "Lets the other Mac's keyboard and mouse control this screen.",
                    action: {
                        _ = Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    })

                if !model.allGranted {
                    HStack(spacing: 8) {
                        Text("After turning a permission on, restart to apply it.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Sidewire") { Permissions.relaunch() }
                            .controlSize(.small)
                    }
                }
            }
            .padding(4)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

private struct PermissionRow: View {
    let granted: Bool
    let title: String
    let why: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(why).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("On").font(.caption).foregroundStyle(.green)
            } else {
                Button("Open Settings", action: action).controlSize(.small)
            }
        }
    }
}
