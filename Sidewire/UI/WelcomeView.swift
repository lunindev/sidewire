import SwiftUI

/// First-run introduction: what Sidewire is, the two roles, connection, and the permissions
/// each side needs. Shown once, then dismissed to the role picker.
struct WelcomeView: View {
    var onDone: () -> Void

    var body: some View {
        ScrollView { welcome } // four rows of copy — must not clip in a short window
    }

    private var welcome: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 46)).foregroundStyle(.tint)
                Text("Welcome to Sidewire")
                    .font(.system(size: 28, weight: .semibold))
                Text("Turn a spare Mac into a second screen for your main one — over Wi-Fi or a Thunderbolt cable.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                // Said first and said plainly: the mental model people arrive with is AirPlay or
                // Sidecar, where the other end needs nothing. Here it does, and nothing in the app
                // used to say so — you'd just sit on a screen that searched forever.
                WelcomeRow(icon: "square.on.square.dashed", title: "You need Sidewire on both Macs",
                           text: "Install and open it on the spare Mac too, then tell each Mac which one it is: the main Mac, or the extra screen.")
                WelcomeRow(icon: "cable.connector", title: "Connect over cable or Wi-Fi",
                           text: "A Thunderbolt cable is fastest — Sidewire spots it and offers a one-click connect. Wi-Fi works too, as long as both Macs are on the same network.")
                WelcomeRow(icon: "lock.shield", title: "Paired & encrypted",
                           text: "Type the 6-digit PIN your spare Mac shows. The picture is TLS-encrypted end to end.")
                WelcomeRow(icon: "checkmark.shield", title: "A couple of permissions",
                           text: "Your main Mac needs Screen Recording and Accessibility — Sidewire walks you through both. Both Macs also need Local Network, which macOS asks about the first time they look for each other.")
            }
            .frame(maxWidth: 500)

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
