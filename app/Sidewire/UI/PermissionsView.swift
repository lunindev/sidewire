import SwiftUI

/// The Main Mac's permission gate: a step between picking the role and the connect screen, not a
/// block parked on top of it forever.
///
/// The old design put this checklist permanently at the top of the connect screen, where it stayed
/// — as a green "Permissions granted" bar — for the entire life of the app. Here it is a gate:
/// while something is missing there is nothing else on screen to be distracted by, and once
/// everything is granted it disappears completely. If a permission is revoked later, RootView
/// re-renders this automatically, so the check is continuous rather than a one-time hurdle.
struct PermissionsGateView: View {
    @ObservedObject var model: PermissionsModel
    /// Back to the picker — the user may simply have picked the wrong Mac. Named for what it
    /// does, not where it goes: it clears this Mac's choice rather than remembering a step.
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    VStack(spacing: 14) {
                        PermissionCard(
                            granted: model.screenRecording,
                            icon: "rectangle.on.rectangle",
                            title: "Screen Recording",
                            why: "Sidewire creates a second screen on this Mac and has to record it to send the picture across. Without this there is nothing to send.",
                            action: {
                                _ = Permissions.requestScreenRecording()
                                Permissions.openScreenRecordingSettings()
                            })

                        PermissionCard(
                            granted: model.accessibility,
                            icon: "keyboard",
                            title: "Accessibility",
                            why: "Lets the keyboard and mouse of your other Mac move the pointer and type on this one. Without this the extra screen is view-only.",
                            action: {
                                _ = Permissions.requestAccessibility()
                                Permissions.openAccessibilitySettings()
                            })
                    }

                    footer
                }
                .padding(28)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label("Change…", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Choose whether this Mac is the main one or the extra screen.")
                Spacer()
            }
            Text("Two things to switch on")
                .font(.system(size: 26, weight: .semibold))
            Text("macOS needs your permission before this Mac can create an extra screen and send the picture to your other Mac. You only do this once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.restartRequired {
            // The one moment a restart genuinely helps: something was granted that this process
            // didn't have when it launched, so its frameworks are still holding the old answer.
            VStack(alignment: .leading, spacing: 10) {
                Label("Almost there — Sidewire has to restart to pick that up.",
                      systemImage: "arrow.clockwise.circle.fill")
                    .font(.callout.weight(.medium))
                Text("macOS only hands a new permission to an app when it starts. Sidewire will reopen itself.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Restart Sidewire") { Permissions.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for you to switch these on in System Settings…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One permission, stated as what it buys the user rather than what the API is called.
private struct PermissionCard: View {
    let granted: Bool
    let icon: String
    let title: String
    let why: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(why)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text("On").font(.callout.weight(.medium)).foregroundStyle(.green)
            } else {
                Button("Turn on…", action: action)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(granted ? AnyShapeStyle(.green.opacity(0.35)) : AnyShapeStyle(.separator)))
    }
}
