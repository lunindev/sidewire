import SwiftUI
import SidewireProtocol

/// First-run role selection: this Mac shares its screen (Source) or shows another
/// Mac's screen (Display).
struct RolePickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Sidewire")
                    .font(.system(size: 30, weight: .semibold))
                Text("Use another Mac as a second display — over Wi-Fi or a Thunderbolt cable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                RoleCard(
                    icon: "macbook.and.iphone",
                    title: "Share this Mac",
                    subtitle: "Creates an extra display here and streams it to another Mac.",
                    guidance: "Pick this on the Mac whose apps and files you want to use.",
                    role: "Source"
                ) { model.setRole(.source) }

                RoleCard(
                    icon: "display",
                    title: "Use as a display",
                    subtitle: "Shows another Mac's screen and forwards your keyboard and mouse.",
                    guidance: "Pick this on the spare Mac that will act as the extra screen.",
                    role: "Display"
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
    let role: String
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
                Text(role.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 240, height: 220, alignment: .topLeading)
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        }
        .buttonStyle(.plain)
    }
}
