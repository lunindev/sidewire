import SwiftUI

/// First-run introduction: what Sidewire is, the two roles, connection, and the permissions
/// each side needs. Shown once, then dismissed to the role picker.
struct WelcomeView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 46)).foregroundStyle(.tint)
                Text("Welcome to Sidewire")
                    .font(.system(size: 28, weight: .semibold))
                Text("Turn a second Mac into an extra display — over Wi-Fi or a Thunderbolt cable.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                WelcomeRow(icon: "macbook.and.iphone", title: "Pick a role on each Mac",
                           text: "“Share this Mac” creates a new display and streams it; “Use as a display” shows it and forwards your keyboard & mouse.")
                WelcomeRow(icon: "cable.connector", title: "Connect over cable or Wi-Fi",
                           text: "A Thunderbolt cable is fastest — Sidewire detects it and offers a one-click connect. Wi-Fi works too.")
                WelcomeRow(icon: "lock.shield", title: "Paired & encrypted",
                           text: "Enter the 6-digit PIN shown on the display Mac. The stream is TLS-encrypted end to end.")
                WelcomeRow(icon: "checkmark.shield", title: "Two permissions",
                           text: "The sharing Mac needs Screen Recording (to capture the screen) and Accessibility (to forward keyboard & mouse). The display Mac needs neither. Sidewire walks you through both.")
            }
            .frame(maxWidth: 480)

            Button(action: onDone) {
                Text("Get Started").frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WelcomeRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
