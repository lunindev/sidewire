import SwiftUI
import SidewireProtocol

/// Asks the only question that matters on first run: **which Mac is this one?**
///
/// The old copy ("Share this Mac" / SOURCE / DISPLAY) described the mechanism instead of the goal,
/// and left users asking what was being shared and with whom. Nobody wants to share a screen —
/// they want a second monitor. So both cards are phrased from the one thing the product actually
/// does: your main Mac gains an extra screen, and that screen lives on the spare Mac.
struct RolePickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // Scrolls so a short window (or longer copy, or a larger accessibility text size) can
        // never push the cards out of sight the way the connect screen's header was.
        ScrollView { picker }
    }

    private var picker: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("An extra screen for your Mac")
                    .font(.system(size: 30, weight: .semibold))
                Text("Sidewire turns a spare Mac into a second screen for your main one — over Wi-Fi or a Thunderbolt cable. Set it up on both Macs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            Text("Which Mac is this?")
                .font(.title3.weight(.medium))

            HStack(spacing: 16) {
                RoleCard(
                    icon: "laptopcomputer.and.arrow.down",
                    title: "Give this Mac another screen",
                    subtitle: "You get a second screen here. The picture shows up on your other Mac.",
                    guidance: "Pick this on the Mac with your apps and files — the one you actually work on.",
                    badge: "MAIN MAC"
                ) { model.setRole(.source) }

                RoleCard(
                    icon: "display",
                    title: "Make this Mac the screen",
                    subtitle: "This Mac becomes the extra screen, and its keyboard and mouse drive your main Mac.",
                    guidance: "Pick this on the spare Mac you want to use as the monitor.",
                    badge: "EXTRA SCREEN"
                ) { model.setRole(.display) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RoleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    /// One plain-language sentence on which Mac this role belongs on (backlog C4).
    let guidance: String
    /// The role in the user's words. Never the wire name: `Role.source`/`.display` cross the
    /// network in HELLO and are frozen in protocol-vectors, but they are engineering terms and
    /// must not leak onto the screen.
    let badge: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 260, height: 240, alignment: .topLeading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
    }
}
