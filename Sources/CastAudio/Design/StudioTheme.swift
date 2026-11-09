import SwiftUI

/// Dark studio console palette, ported from the Android reference app
/// (StudioBackground / CyanAccent / EmeraldLive / ErrorCoral).
enum StudioTheme {
    static let background = Color(red: 0.055, green: 0.063, blue: 0.078)
    static let surface = Color(red: 0.086, green: 0.098, blue: 0.118)
    static let surfaceRaised = Color(red: 0.114, green: 0.129, blue: 0.153)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let cyan = Color(red: 0.204, green: 0.788, blue: 0.929)
    static let live = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let danger = Color(red: 0.937, green: 0.376, blue: 0.325)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textMuted = Color.white.opacity(0.35)

    static let displayFont = Font.system(size: 22, weight: .bold, design: .rounded)
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let monoFont = Font.system(size: 12, design: .monospaced)
}

/// A single console card surface.
struct StudioCard<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(StudioTheme.titleFont)
                    .foregroundStyle(StudioTheme.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(StudioTheme.monoFont)
                        .foregroundStyle(StudioTheme.textMuted)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(StudioTheme.stroke, lineWidth: 1)
        )
    }
}

/// Small status pill used for the four independent state dimensions.
struct StatusPill: View {
    let label: String
    let active: Bool
    var tint: Color = StudioTheme.accent

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? tint : StudioTheme.textMuted)
                .frame(width: 7, height: 7)
            Text(label)
                .font(StudioTheme.monoFont)
                .foregroundStyle(active ? StudioTheme.textPrimary : StudioTheme.textMuted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(StudioTheme.surfaceRaised)
        )
        .overlay(
            Capsule().stroke(active ? tint.opacity(0.45) : StudioTheme.stroke, lineWidth: 1)
        )
    }
}
