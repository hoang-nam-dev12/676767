import SwiftUI
import UIKit
import AudioToolbox

enum AppTheme {
    static let accent = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.18, green: 0.52, blue: 1.00, alpha: 1.00)  // #2E85FF blue dark
                : UIColor(red: 0.10, green: 0.40, blue: 0.90, alpha: 1.00)  // #1A66E6 blue light
        }
    )
    /// Dedicated brighter blue for the Free Fire category selector.
    static let aimHoloBlue = Color(
        red: 0.08,
        green: 0.62,
        blue: 1.0
    )
    static let pageBackground = Color(uiColor: .systemBackground)
    static let consoleBackground = Color(uiColor: .secondarySystemBackground)
    static let pageInset: CGFloat = 16
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 18

    // 3105 repository UI compatibility constants.
    static let contentCardCornerRadius: CGFloat = 20
    static let contentCardInset: CGFloat = 16
    static let contentCardPadding: CGFloat = 16
}

struct AppCardBorder: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: AppTheme.contentCardCornerRadius,
            style: .continuous
        )
        .strokeBorder(
            Color(uiColor: .separator).opacity(0.22),
            lineWidth: 0.5
        )
        .accessibilityHidden(true)
    }
}


// MARK: - Global Status Notification
struct FluxStatusNotification: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let isOn: Bool
}

@MainActor
final class FluxStatusNotificationCenter: ObservableObject {
    static let shared = FluxStatusNotificationCenter()
    @Published private(set) var notification: FluxStatusNotification?

    private var dismissTask: Task<Void, Never>?

    private init() {}

    func post(title: String, detail: String, isOn: Bool) {
        dismissTask?.cancel()
        let value = FluxStatusNotification(title: title, detail: detail, isOn: isOn)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            notification = value
        }
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.30)) {
                self?.notification = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.24)) {
            notification = nil
        }
    }
}

struct FluxStatusNotificationBanner: View {
    @ObservedObject private var center = FluxStatusNotificationCenter.shared
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        if let item = center.notification {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(appearance.resolvedBorderColor.opacity(0.14))
                    Image(systemName: item.isOn ? "power.circle.fill" : "power.circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(appearance.resolvedBorderColor)
                        .shadow(color: appearance.resolvedBorderColor.opacity(0.75), radius: 8)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.uppercased())
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.9)
                        .foregroundStyle(.white)
                    Text(item.detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Text(item.isOn ? "ON" : "OFF")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(appearance.resolvedBorderColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(appearance.resolvedBorderColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 220, maxWidth: 330, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.black.opacity(0.72))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.clear, lineWidth: 0)
            }
            .shadow(color: appearance.resolvedBorderColor.opacity(0.22), radius: 16, y: 7)
            .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
            .onTapGesture { center.dismiss() }
        }
    }
}

// MARK: - Technology Border
extension View {
    /// Futuristic edge treatment with stronger centered top/bottom accents.
    func techBorder(enabled: Bool, color: Color, cornerRadius: CGFloat, width: Double) -> some View {
        modifier(TechnologyBorderModifier(
            enabled: enabled,
            color: color,
            cornerRadius: cornerRadius,
            width: CGFloat(min(max(width, 0.5), 4.0))
        ))
    }
}

private struct TechnologyBorderModifier: ViewModifier {
    let enabled: Bool
    let color: Color
    let cornerRadius: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            ZStack {
                // Keep the geometry alive and fade only its visual alpha. This
                // avoids layout churn when the user toggles technology borders.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.clear, lineWidth: 0)

                GeometryReader { proxy in
                    let inset = max(width * 0.8, 1.0)
                    let accentWidth = min(max(proxy.size.width * 0.34, 42), 180)
                    let accentOpacity = enabled ? 1.0 : 0.0

                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(color.opacity(0.95 * accentOpacity))
                            .frame(width: accentWidth, height: max(width * 1.55, 1.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                        Spacer()
                        Rectangle()
                            .fill(color.opacity(0.82 * accentOpacity))
                            .frame(width: accentWidth, height: max(width * 1.55, 1.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .padding(.horizontal, inset + width)
                    .padding(.vertical, inset + width)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.22), value: enabled)
    }
}

// MARK: - Global futuristic button chrome
extension View {
    /// Consistent cyber/futuristic edge treatment for interactive controls.
    func techButtonChrome() -> some View {
        modifier(TechButtonChromeModifier())
    }
}

private struct TechButtonChromeModifier: ViewModifier {
    @ObservedObject private var appearance = AppearanceSettings.shared

    func body(content: Content) -> some View {
        content
            .cosmicTapFeedback()
            .overlay {
                GeometryReader { proxy in
                    let width = CGFloat(min(max(appearance.buttonBorderWidth, 0.5), 4))
                    let radius = CGFloat(min(max(appearance.buttonCornerRadius, 6), 30))
                    let accentWidth = min(max(proxy.size.width * 0.30, 24), 110)
                    let alpha = appearance.technologyBorderEnabled ? 1.0 : 0.0
                    ZStack {
                        // Low-cost glass layer: kept subtle so the label remains crisp.
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(appearance.buttonGlassOpacity)

                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.clear, lineWidth: 0)

                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(appearance.resolvedBorderColor.opacity(0.95 * alpha))
                                .frame(width: accentWidth, height: max(width * 1.35, 1.4))
                            Spacer()
                            Rectangle()
                                .fill(appearance.resolvedBorderColor.opacity(0.72 * alpha))
                                .frame(width: accentWidth, height: max(width * 1.35, 1.4))
                        }
                        .padding(.horizontal, max(width, 1))
                        .padding(.vertical, max(width, 1))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: CGFloat(min(max(appearance.buttonCornerRadius, 6), 30)),
                    style: .continuous
                )
                .stroke(
                    appearance.buttonGlowEnabled
                        ? Color(hex: appearance.buttonGlowColorHex) ?? appearance.resolvedBorderColor
                        : .clear,
                    lineWidth: max(appearance.buttonBorderWidth, 0.75)
                )
                .shadow(
                    color: appearance.buttonGlowEnabled
                        ? (Color(hex: appearance.buttonGlowColorHex) ?? appearance.resolvedBorderColor)
                            .opacity(0.72 * appearance.buttonGlowIntensity)
                        : .clear,
                    radius: appearance.buttonGlowEnabled
                        ? CGFloat(appearance.buttonGlowRadius)
                        : 0
                )
                .shadow(
                    color: appearance.buttonGlowEnabled
                        ? (Color(hex: appearance.buttonGlowColorHex) ?? appearance.resolvedBorderColor)
                            .opacity(0.28 * appearance.buttonGlowIntensity)
                        : .clear,
                    radius: appearance.buttonGlowEnabled
                        ? CGFloat(appearance.buttonGlowRadius * 0.42)
                        : 0
                )
                .allowsHitTesting(false)
            }
            .animation(
                appearance.animationsEnabled
                    ? .easeInOut(duration: 0.22 * appearance.animationDurationMultiplier)
                    : nil,
                value: appearance.technologyBorderEnabled
            )
    }
}

/// Centralized tactile/click feedback for technology controls.
/// Uses system haptics plus the built-in keyboard-click tone, so no remote
/// audio asset or network request is required.
enum CosmicInteractionFeedback {
    static func fire() {
        guard AppearanceSettings.shared.hapticsEnabled else {
            AudioServicesPlaySystemSound(1104)
            return
        }

        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.72)
        AudioServicesPlaySystemSound(1104)
    }
}

private struct CosmicTapFeedbackModifier: ViewModifier {
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
                    .scaleEffect(pulse ? 1.035 : 1.0)
                    .opacity(pulse ? 0.0 : 1.0)
                    .allowsHitTesting(false)
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { _ in
                        CosmicInteractionFeedback.fire()
                        guard AppearanceSettings.shared.animationsEnabled else { return }
                        withAnimation(.easeOut(duration: 0.24)) { pulse = true }
                        withAnimation(.easeIn(duration: 0.22).delay(0.02)) { pulse = false }
                    }
            )
    }
}

extension View {
    /// Adds the shared cosmic tap pulse + tactile audio/haptic response.
    func cosmicTapFeedback() -> some View {
        modifier(CosmicTapFeedbackModifier())
    }
}

// MARK: - App icon glow
extension View {
    /// Lightweight configurable glow for launchable application icons.
    func appLaunchIconGlow() -> some View {
        modifier(AppLaunchIconGlowModifier())
    }
}

private struct AppLaunchIconGlowModifier: ViewModifier {
    @ObservedObject private var appearance = AppearanceSettings.shared

    func body(content: Content) -> some View {
        let color = Color(hex: appearance.appButtonGlowColorHex) ?? appearance.resolvedAppButtonColor
        content
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        appearance.appButtonGlowEnabled
                            ? color.opacity(0.55 * appearance.appButtonGlowIntensity)
                            : .clear,
                        lineWidth: 1.2
                    )
                    .shadow(
                        color: appearance.appButtonGlowEnabled
                            ? color.opacity(0.72 * appearance.appButtonGlowIntensity)
                            : .clear,
                        radius: appearance.appButtonGlowEnabled
                            ? CGFloat(appearance.appButtonGlowRadius * 0.65)
                            : 0
                    )
                    .allowsHitTesting(false)
            }
    }
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).techButtonChrome()
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = UIImage(named: "NDMLogo")
                ?? UIImage(named: "AppIcon60x60")
                ?? Bundle.main.path(forResource: "AppIcon60x60@2x", ofType: "png").flatMap(UIImage.init(contentsOfFile:))
                ?? UIImage(named: "AppIcon") {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}


// MARK: - Shared Developer Info

/// Centralizes Dynamic Transparency normalization for every Developer Info surface.
/// Keeping this in one place prevents individual screens from drifting out of sync.
private enum DeveloperInfoAppearance {
    static func normalized(_ value: Double) -> Double {
        min(max(value, 0.05), 1.0)
    }
}

/// Shared press feedback used by Developer Info surfaces.
/// Transparency is intentionally not modified here: every interaction state keeps
/// the exact Dynamic Transparency value selected by the user.
private struct DeveloperPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.982 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct DeveloperInfoCard: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    var size: CGFloat = 88
    var action: (() -> Void)? = nil

    init(size: CGFloat = 88, action: (() -> Void)? = nil) {
        self.size = size
        self.action = action
    }

    var body: some View {
        HStack {
            Spacer()
            Group {
                if let img = UIImage(named: "NDMLogo")
                    ?? UIImage(named: "AppIcon60x60")
                    ?? UIImage(named: "AppIcon") {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "shield.fill")
                        .font(.system(size: size * 0.5))
                        .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.72))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.40, blue: 0.75).opacity(0.65),
                                Color(red: 0.85, green: 0.30, blue: 0.90).opacity(0.35),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: Color(red: 1.0, green: 0.25, blue: 0.65).opacity(0.45), radius: 16, y: 6)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}


