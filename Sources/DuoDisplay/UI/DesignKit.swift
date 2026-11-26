import SwiftUI

/// Shared look of all DuoDisplay windows: System Settings–style grouped forms, tinted symbol
/// tiles, a status dot, key caps for shortcuts and one critically damped spring for state changes.
enum Design {
    /// Critically damped (no overshoot): state changes settle calmly, nothing bounces.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1.0)
    /// Press feedback: in fast on press-down, out a little slower on release.
    static func press(_ pressed: Bool) -> Animation {
        .spring(response: pressed ? 0.12 : 0.3, dampingFraction: 1.0)
    }
}

extension View {
    /// Animates layout/state changes driven by `value` with the house spring – or not at all
    /// when “Reduce motion” is on (the change then simply appears).
    func designAnimation<V: Equatable>(value: V) -> some View {
        modifier(DesignAnimation(value: value))
    }
}

private struct DesignAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Design.spring, value: value)
    }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass surface on macOS 26+, a solid control-colored card with a soft shadow before.
    /// `interactive` lets the glass react to press and hover itself (for clickable surfaces).
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Self.glass(interactive: interactive, tint: tint), in: shape)
        } else {
            self.background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        }
    }

    @available(macOS 26, *)
    private static func glass(interactive: Bool, tint: Color?) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

// MARK: - Status

/// What a status dot / tile color means. Colors follow macOS conventions.
enum StatusTone: Equatable {
    case ok, working, warning, error, idle

    var color: Color {
        switch self {
        case .ok: return .green
        case .working: return .orange
        case .warning: return .orange
        case .error: return .red
        case .idle: return .secondary
        }
    }
}

/// Small colored dot in front of a status text.
struct StatusDot: View {
    let tone: StatusTone

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// White SF Symbol on a colored, continuous-corner square – the System Settings row icon.
struct SymbolTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(color.gradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

/// One row in a grouped form: tile, title, optional detail and warning, trailing controls.
struct StatusRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var detail: String? = nil
    var warning: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SymbolTile(systemName: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning {
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing.controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}

extension StatusRow where Trailing == EmptyView {
    init(symbol: String, color: Color, title: String, detail: String? = nil, warning: String? = nil) {
        self.init(symbol: symbol, color: color, title: title, detail: detail, warning: warning) { EmptyView() }
    }
}

/// Inline problem notice inside a form section.
struct NoticeRow: View {
    let text: String
    var tone: StatusTone = .warning

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: tone == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tone.color)
        }
        .font(.callout)
    }
}

extension View {
    /// Section footers read top-left like body text (grouped forms center/trail them otherwise).
    func footerText() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Header

/// Large icon, title and live status at the top of a mode window.
struct PageHeader: View {
    let symbol: String
    let title: String
    let status: String
    let tone: StatusTone

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(.tint.opacity(0.12))
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    StatusDot(tone: tone)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 10)
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shortcuts

/// A shortcut such as ⌃⌥⌘D drawn as one key cap.
struct KeyCombo: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .tracking(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .glassSurface(in: Capsule())
            .accessibilityLabel(Self.spoken(keys))
    }

    /// VoiceOver reads the modifier glyphs as words.
    private static func spoken(_ keys: String) -> String {
        keys.map { c -> String in
            switch c {
            case "⌃": return "Control "
            case "⌥": return "Option "
            case "⌘": return "Befehl "
            case "⇧": return "Umschalt "
            default: return String(c)
            }
        }.joined()
    }
}

/// "Umschalten jederzeit mit ⌃⌥⌘D" with the shortcut as a key cap.
struct ShortcutHint: View {
    let text: String
    let keys: String
    var trailing: String = ""

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
            KeyCombo(keys)
            if !trailing.isEmpty { Text(trailing) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// Live numbers (latency, fps …) – monospaced so they don't jitter while updating.
struct StatsText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
