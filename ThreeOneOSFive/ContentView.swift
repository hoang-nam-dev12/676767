import Foundation
import SwiftUI
import UIKit
import AVKit
import AVFoundation
#if os(macOS)
import AppKit
#endif

// MARK: - 1. Server License Auth Manager
// Endpoint is configured by ServerLicenseCheckURL in Info.plist.
// Response: { valid, expires_at, app_name, lifetime, note, message }
class KeyAuthManager: ObservableObject {
    // ── Persistent storage ──
    @AppStorage("saved_key")      var savedKey:     String = ""
    @AppStorage("key_name")       var keyName:      String = ""
    @AppStorage("key_duration")   var keyDuration:  String = ""
    @AppStorage("key_expiry")     var keyExpiry:    String = ""
    @AppStorage("key_note")       var keyNote:      String = ""
    @AppStorage("key_lifetime")   var keyLifetime:  Bool   = false
    @AppStorage("key_expiry_timestamp") var keyExpiryTimestamp: Double = 0

    // ── Runtime state ──
    @Published var isAuthorized:      Bool  = false
    @Published var isAuthenticating:  Bool  = true
    @Published var errorMessage:      String? = nil
    @Published var isMaintenanceMode: Bool  = false
    @Published var isPatchVisible:    Bool  = true
    @Published var isExitingApp:      Bool  = false
    @Published var isActivationTransitioning: Bool = false

    // Verification is cancellable so logging out cannot be followed by a stale
    // network response that re-authorizes the UI or races the key-login screen.
    private var verificationTask: URLSessionDataTask?
    private var verificationSession: URLSession?
    private var verificationGeneration: UInt64 = 0

    private struct LicenseCheckResponse: Decodable {
        let valid: Bool
        let expiresAt: String?
        let appName: String?
        let lifetime: Bool?
        let note: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case valid
            case expiresAt = "expires_at"
            case appName = "app_name"
            case lifetime
            case note
            case message
        }
    }

    private static var endpoint: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ServerLicenseCheckURL") as? String else {
            return nil
        }
        return URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static var deviceUDID: String {
        let storageKey = "server_license_device_udid"
        if let existing = UserDefaults.standard.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: storageKey)
        return identifier
    }

    // ── Format date string — mirrors fmtDate() in HTML ──
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                             .withColonSeparatorInTime, .withFullDate]
        if let date = iso.date(from: normalized) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static func formatDate(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Không giới hạn" }
        // Try ISO-style: "2026-12-31 23:59:59" or "2026-12-31T23:59:59"
        let normalized = raw.replacingOccurrences(of: " ", with: "T")
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                             .withColonSeparatorInTime, .withFullDate]
        let parsed = fmt.date(from: normalized)
            ?? {
                let f2 = DateFormatter()
                f2.locale = Locale(identifier: "en_US_POSIX")
                f2.timeZone = TimeZone(secondsFromGMT: 0)
                f2.dateFormat = "yyyy-MM-dd HH:mm:ss"
                return f2.date(from: raw)
            }()
        guard let d = parsed else { return raw }
        let out = DateFormatter()
        out.locale     = Locale(identifier: "vi_VN")
        out.dateFormat = "HH:mm - dd/MM/yyyy"
        return out.string(from: d)
    }

    func verifyKey(inputKey: String? = nil) {
        verificationGeneration &+= 1
        let generation = verificationGeneration

        verificationTask?.cancel()
        verificationTask = nil
        verificationSession?.invalidateAndCancel()
        verificationSession = nil

        isAuthenticating = true
        errorMessage     = nil

        let candidate = (inputKey ?? savedKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !candidate.isEmpty else {
            isAuthenticating = false
            isAuthorized = false
            return
        }
        guard let endpoint = Self.endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            isAuthenticating = false
            isAuthorized = false
            errorMessage = "Ứng dụng chưa cấu hình Server Key API."
            return
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: candidate),
            URLQueryItem(name: "udid", value: Self.deviceUDID)
        ]
        guard let url = components.url else {
            isAuthenticating = false
            isAuthorized = false
            errorMessage = "Không thể tạo yêu cầu kiểm tra key."
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        verificationSession = session

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        verificationTask = session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self, self.verificationGeneration == generation else { return }
                self.verificationTask = nil
                self.verificationSession = nil
                self.isAuthenticating = false

                if let error {
                    self.isAuthorized = false
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data else {
                    self.isAuthorized = false
                    self.errorMessage = "Server Key không phản hồi hợp lệ."
                    return
                }

                do {
                    let result = try JSONDecoder().decode(LicenseCheckResponse.self, from: data)
                    guard result.valid else {
                        self.isAuthorized = false
                        self.errorMessage = result.message ?? "Key không hợp lệ."
                        return
                    }

                    let lifetime = result.lifetime ?? (result.expiresAt == nil)
                    let expiryDate = Self.parseDate(result.expiresAt)
                    guard lifetime || expiryDate != nil else {
                        self.isAuthorized = false
                        self.errorMessage = "Server trả về ngày hết hạn không hợp lệ."
                        return
                    }

                    let resolvedAppName = result.appName?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.savedKey = candidate
                    self.keyName = resolvedAppName.isEmpty ? "Duy Mạnh Store VIP" : resolvedAppName
                    self.keyNote = result.note ?? ""
                    self.keyLifetime = lifetime
                    self.keyDuration = lifetime ? "Vĩnh viễn" : "Có thời hạn"
                    self.keyExpiry = lifetime ? "Vĩnh viễn" : Self.formatDate(result.expiresAt)
                    self.keyExpiryTimestamp = lifetime ? 0 : (expiryDate?.timeIntervalSince1970 ?? 0)
                    self.isAuthorized = true
                    self.isPatchVisible = true
                    self.errorMessage = nil
                    self.isActivationTransitioning = true

                    let duration = AppearanceSettings.shared.animationsEnabled ? 1.15 : 0.05
                    DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                        self?.isActivationTransitioning = false
                    }
                } catch {
                    self.isAuthorized = false
                    self.errorMessage = "Phản hồi Server Key không đúng định dạng."
                }
            }
        }
        verificationTask?.resume()
    }

    func enterMaintenanceMode() {
        verificationGeneration &+= 1
        verificationTask?.cancel()
        verificationTask = nil
        verificationSession?.invalidateAndCancel()
        verificationSession = nil
        isMaintenanceMode = true
        isAuthorized = true
        isAuthenticating = false
        isPatchVisible = false
        isExitingApp = false
        errorMessage = nil
    }

    func leaveMaintenanceMode() {
        isMaintenanceMode = false
        isPatchVisible = true
        if savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isAuthorized = false
        }
    }

    /// Clears the key and deterministically returns ContentView to KeyActivationView.
    /// Any in-flight verification is invalidated first, preventing a late callback
    /// from restoring the authorized state after logout.
    func logout() {
        verificationGeneration &+= 1
        verificationTask?.cancel()
        verificationTask = nil
        verificationSession?.invalidateAndCancel()
        verificationSession = nil

        ["saved_key","key_name","key_duration","key_expiry","key_note","key_expiry_timestamp"].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
        UserDefaults.standard.set(false, forKey: "key_lifetime")

        savedKey = ""
        keyName = ""
        keyDuration = ""
        keyExpiry = ""
        keyExpiryTimestamp = 0
        keyNote = ""
        keyLifetime = false

        errorMessage = nil
        isAuthenticating = false
        isAuthorized = false
        isPatchVisible = true
        isExitingApp = false
        isMaintenanceMode = false
    }

    private func triggerMaintenanceSequence() {
        isExitingApp = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
    }
}

// MARK: _RedirectDelegate
private final class _RedirectDelegate: NSObject, URLSessionTaskDelegate {
    private var hops = 0
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        hops += 1
        guard hops <= 2 else { completionHandler(nil); return }
        var r = request
        if var c = URLComponents(url: request.url ?? URL(string: "https://")!,
                                 resolvingAgainstBaseURL: false), c.scheme == "http" {
            c.scheme = "https"; r.url = c.url ?? request.url
        }
        completionHandler(r)
    }
}

// MARK: - 2. Maintenance view
struct MaintenanceView: View {
    @ObservedObject var config: AppRuntimeConfig
    @State private var isPresented = true
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.34).ignoresSafeArea()
            if isPresented {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.yellow)

                    Text("HỆ THỐNG BẢO TRÌ")
                        .font(.title3.weight(.bold))

                    Text(config.maintenanceNotice)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !config.maintenanceButtons.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(config.maintenanceButtons) { button in
                                Button(button.label) {
                                    guard let url = URL(string: button.url) else { return }
                                    UIApplication.shared.open(url)
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }

                    Button("Đóng") {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                }
                .padding(24)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .padding(.horizontal, 24)
            }
        }
        .onAppear {
            scheduleTimer()
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.maintenanceInterval, repeats: true) { _ in
            DispatchQueue.main.async {
                isPresented = true
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}

// MARK: - 3. Key Activation view
/// Premium activation surface shared by first-launch and re-authentication flows.
/// The wallpaper remains visible outside the protected card, while the card and
/// input control use layered materials/tints so app content cannot bleed through.
// MARK: - KeyActivationView
/// Login screen that mirrors checkkey.html:
///   accent purple #7f5af0 / green #2cb67d / red #ff4d6d
///   card = glassmorphism dark, slideUp animation
///   result card = green (valid) / red (invalid) with rows
struct KeyActivationView: View {
    @ObservedObject var authManager: KeyAuthManager
    @State private var inputKey:       String = ""
@State private var keyVisible:    Bool   = false
    @State private var appeared:       Bool   = false
    @State private var cardSlid:       Bool   = false
    @State private var showDevMenu:    Bool   = false
    @State private var btnPressed:     Bool   = false
    @FocusState private var focused:   Bool
    @ObservedObject private var appearance = AppearanceSettings.shared

    private var isFuturisticTheme: Bool {
        appearance.appThemeMode == .futuristic
    }

    private var primaryTextColor: Color {
        isFuturisticTheme ? .white : Color.black.opacity(0.88)
    }

    private var secondaryTextColor: Color {
        isFuturisticTheme ? cMuted : Color.black.opacity(0.56)
    }

    private var loginBackgroundColor: Color {
        appearance.resolvedKeyLoginBackgroundColor
    }

    private var loginBorderColor: Color {
        appearance.resolvedKeyLoginBorderColor
    }

    private var loginCornerRadius: CGFloat {
        CGFloat(min(max(appearance.keyLoginCornerRadius, 12), 36))
    }

    // HTML palette
    private let cAccent  = Color(red: 0.498, green: 0.353, blue: 0.941)  // #7f5af0
    private let cGreen   = Color(red: 0.173, green: 0.714, blue: 0.490)  // #2cb67d
    private let cRed     = Color(red: 1.000, green: 0.302, blue: 0.427)  // #ff4d6d
    private let cWarn    = Color(red: 1.000, green: 0.718, blue: 0.012)  // #ffb703
    private let cBG1     = Color(red: 0.051, green: 0.043, blue: 0.129)  // #0d0b21
    private let cBG2     = Color(red: 0.165, green: 0.137, blue: 0.349)  // #2a2359
    private let cMuted   = Color(red: 0.663, green: 0.639, blue: 0.769)  // #a9a3c4
    private let cCard    = Color(red: 0.086, green: 0.063, blue: 0.161)  // #161029

    var body: some View {
        ZStack {
            // ── Background: animated gradient matching HTML ──
            ZStack {
                LinearGradient(
                    colors: isFuturisticTheme
                        ? [loginBackgroundColor, Color(red: 0.015, green: 0.02, blue: 0.04)]
                        : [loginBackgroundColor, Color.white.opacity(0.96)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // Radial accents
                RadialGradient(colors: [cAccent.opacity(isFuturisticTheme ? 0.13 : 0.05), .clear],
                               center: .init(x: 0.1, y: -0.05),
                               startRadius: 0, endRadius: 650)
                RadialGradient(colors: [cGreen.opacity(isFuturisticTheme ? 0.10 : 0.035), .clear],
                               center: .init(x: 1.1, y: 0.1),
                               startRadius: 0, endRadius: 520)
                // Background wallpaper if set
                GlobalBackground().opacity(isFuturisticTheme ? 0.16 : 0.05)
            }
            .ignoresSafeArea()

            // ── Content: mathematically centered in the available screen ──
            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        loginCard
                            .frame(maxWidth: 460)
                            .frame(maxWidth: .infinity)
                            .offset(y: cardSlid ? 0 : 24)
                            .opacity(cardSlid ? 1 : 0)
                    }
                    .frame(minHeight: max(geometry.size.height, 1),
                           alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                .scrollIndicators(.hidden)
            }
        }

        .animation(.easeOut(duration: 0.20), value: authManager.isAuthenticating)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: authManager.errorMessage)
        .onAppear {
            inputKey = authManager.savedKey
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.55)) { cardSlid = true }
            withAnimation(.spring(response: 0.60, dampingFraction: 0.82).delay(0.15)) { appeared = true }
        }
    }

    // ── Main glass card ──
    private var loginCard: some View {
        VStack(spacing: 0) {
            // ─ Logo row (mirrors .logo) ─
            HStack(spacing: 12) {
                // Badge with key icon + warn glow
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(
                            RadialGradient(colors: [Color.white.opacity(0.08), .clear],
                                           center: .init(x: 0.3, y: 0.2),
                                           startRadius: 0, endRadius: 46)
                        )
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.11, green: 0.08, blue: 0.20),
                                                      Color(red: 0.04, green: 0.03, blue: 0.08)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(cAccent)
                }
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                )
                .shadow(color: cAccent.opacity(0.40), radius: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Kiểm tra License Key")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(primaryTextColor)
                    Text("Duy Mạnh Store")
                        .font(.system(size: 12.5))
                        .foregroundColor(secondaryTextColor)
                }
                Spacer()
            }
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 24)

            Divider()
                .background((isFuturisticTheme ? Color.white : Color.black).opacity(0.10))
                .padding(.horizontal, 30)

            // ─ Input + button ─
            VStack(spacing: 14) {

                // Label
                HStack {
                    Text("Nhập Key")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(secondaryTextColor)
                    Spacer()
                }

                // Input field
                keyField

                // Action button
                activateButton

                // ─ Result card (mirrors res-card) ─
                if authManager.isAuthenticating {
                    loadingRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let err = authManager.errorMessage {
                    errorCard(err)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if authManager.isAuthorized {
                    successCard
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }

            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)

            // ─ NDM PROXY Icon ─
            DeveloperInfoCard()
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)
            .animation(.spring(response: 0.55, dampingFraction: 0.88).delay(0.12), value: appeared)
        }
        .background {
            // Glassmorphism card bg
            RoundedRectangle(cornerRadius: loginCornerRadius, style: .continuous)
                .fill(loginBackgroundColor.opacity(appearance.keyLoginBackgroundOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: loginCornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(isFuturisticTheme ? 0.28 : 0.18))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: loginCornerRadius, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
                .shadow(
                    color: appearance.keyLoginBorderStyle == .transparent
                        ? .clear
                        : loginBorderColor.opacity(isFuturisticTheme ? 0.32 : 0.10),
                    radius: isFuturisticTheme ? 14 : 7
                )
        }
        .shadow(color: .black.opacity(isFuturisticTheme ? 0.67 : 0.18), radius: isFuturisticTheme ? 40 : 24, y: isFuturisticTheme ? 20 : 10)
    }

    // ── Secure key input field ──
    private var keyField: some View {
        HStack(spacing: 8) {
            Group {
                if keyVisible {
                    TextField("XXXX-XXXX-XXXX-XXXX", text: $inputKey)
                } else {
                    SecureField("XXXX-XXXX-XXXX-XXXX", text: $inputKey)
                }
            }
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .focused($focused)
            .foregroundColor(primaryTextColor)
            .font(.system(size: 15, design: .monospaced))
            .tint(cAccent)
            .onChange(of: inputKey) { v in
                let upper = v.uppercased()
                if upper != v { inputKey = upper }
            }
            .onSubmit { submit() }

            Button {
                guard !inputKey.isEmpty else { return }
                UIPasteboard.general.string = inputKey
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(cAccent)
                    .frame(width: 34, height: 34)
                    .background(cAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain).techButtonChrome()
            .disabled(inputKey.isEmpty)
            .accessibilityLabel("Sao chép Key")

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    keyVisible.toggle()
                }
            } label: {
                Image(systemName: keyVisible ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(keyVisible ? cAccent : secondaryTextColor)
                    .frame(width: 34, height: 34)
                    .background(
                        (keyVisible ? cAccent : Color.white).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(.plain).techButtonChrome()
            .accessibilityLabel(keyVisible ? "Ẩn Key" : "Hiện Key")

            Button {
                guard let p = UIPasteboard.general.string else { return }
                withAnimation(.easeInOut(duration: 0.16)) {
                    inputKey = p.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(cAccent)
                    .frame(width: 34, height: 34)
                    .background(cAccent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain).techButtonChrome()
            .accessibilityLabel("Dán Key")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isFuturisticTheme ? Color.black.opacity(0.42) : Color.white.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
                .shadow(color: focused ? cAccent.opacity(0.20) : .clear, radius: 5)
        }
        .animation(.easeInOut(duration: 0.18), value: focused)
    }

    // ── Activate button (gradient #7f5af0 → #9b6bff, hover lift) ──
    private var activateButton: some View {
        Button { submit() } label: {
            HStack(spacing: 8) {
                if authManager.isAuthenticating {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                        .transition(.opacity)
                } else {
                    Image(systemName: "key.fill")
                        .font(.system(size: 15, weight: .bold))
                }
                Text(authManager.isAuthenticating ? "Đang xác thực Server Key..." : "Kích Hoạt Key")
                    .fontWeight(.bold)
                    .font(.system(size: 14.5))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).techButtonChrome()
        .foregroundColor(primaryTextColor)
        .background(
            LinearGradient(colors: [cAccent, Color(red: 0.608, green: 0.420, blue: 1.0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
        .shadow(color: cAccent.opacity(0.55), radius: 16, y: 8)
        .scaleEffect(btnPressed ? 0.97 : 1.0)
        .brightness(btnPressed ? -0.04 : 0)
        .animation(.easeOut(duration: 0.12), value: btnPressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in btnPressed = true }
            .onEnded   { _ in btnPressed = false }
        )
        .disabled(authManager.isAuthenticating)
        .opacity(authManager.isAuthenticating ? 0.62 : 1)
    }

    // ── Loading row ──
    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().tint(cAccent).scaleEffect(0.85)
            Text("Đang kiểm tra key...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(secondaryTextColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(cAccent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // ── Error card (res-bad) ──
    private func errorCard(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(cRed)
                Text(msg)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.561, blue: 0.639)) // #ff8fa3
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
        }
        .background(cRed.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // ── Success card (res-ok) ──
    private var successCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(cGreen)
                Text("Key hợp lệ")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(red: 0.357, green: 0.890, blue: 0.643)) // #5be3a4
                Spacer()
                // Logout
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        authManager.logout()
                        inputKey = ""
                    }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(cRed)
                }
                .buttonStyle(.plain).techButtonChrome()
                .accessibilityLabel("Đăng xuất key")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider().background((isFuturisticTheme ? Color.white : Color.black).opacity(0.08)).padding(.horizontal, 18)

            // Rows (mirrors row() in HTML)
            VStack(spacing: 0) {
                resultRow(key: "Ứng dụng",    value: authManager.keyName,
                          isMono: false)
                resultRow(key: "Hạn sử dụng", value: authManager.keyExpiry,
                          isMono: true)
                if !authManager.keyNote.isEmpty {
                    resultRow(key: "Ghi chú", value: authManager.keyNote, isMono: false)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .background(cGreen.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // ── Table row ──
    private func resultRow(key: String, value: String, isMono: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 13))
                .foregroundColor(secondaryTextColor)
            Spacer()
            Text(value)
                .font(isMono
                      ? .system(size: 13, weight: .semibold, design: .monospaced)
                      : .system(size: 13, weight: .semibold))
                .foregroundColor(primaryTextColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Divider().background((isFuturisticTheme ? Color.white : Color.black).opacity(0.06))
        }
    }

    // ── Submit ──
    private func submit() {
        focused = false
        let trimmed = inputKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !authManager.isAuthenticating else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            authManager.verifyKey(inputKey: trimmed.isEmpty ? nil : trimmed)
        }
    }
}

// MARK: - Chức Năng AT
private enum DNSProfileInstaller {
    static let profileURL = URL(string: "https://appfluxcore.site/dns.1053.mobileconfig")!

    @MainActor
    static func openProfile() {
        UIApplication.shared.open(profileURL, options: [:], completionHandler: nil)
    }
}

struct DNSProfileItem: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let filename: String
    let url: String
    let status: Bool
    let created_at: String
}

@MainActor
final class DNSProfileFetcher: ObservableObject {
    @Published private(set) var items: [DNSProfileItem] = []
    @Published private(set) var isLoading = false

    private let endpoint = URL(string: "https://appfluxcore.site/api/dns_list.php")!

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            let decoded = try JSONDecoder().decode([DNSProfileItem].self, from: data)
            items = decoded.filter(\.status)
        } catch {
            log("dns: fetch failed – \(error.localizedDescription)")
        }
    }
}

struct ATView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @StateObject private var dnsFetcher = DNSProfileFetcher()
    @State private var pressedID: String?

    var body: some View {
        ZStack {
            GlobalBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    TechSurface(cornerRadius: 22) {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.14))
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.system(size: 25, weight: .bold))
                                    .foregroundStyle(AppTheme.accent)
                                    .shadow(color: AppTheme.accent.opacity(0.65), radius: 10)
                            }
                            .frame(width: 54, height: 54)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("DNS ANTI CHỐNG QUÉT")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                Text("Danh sách DNS được cung cấp từ Web Admin")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }

                    if dnsFetcher.isLoading && dnsFetcher.items.isEmpty {
                        ProgressView("Đang tải DNS...")
                            .frame(maxWidth: .infinity, minHeight: 100)
                    } else if dnsFetcher.items.isEmpty {
                        TechSurface(cornerRadius: 18) {
                            Text("Chưa có DNS Anti được Admin công khai.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 90)
                        }
                    } else {
                        ForEach(dnsFetcher.items) { item in
                            TechSurface(cornerRadius: 18) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(item.name)
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                    if !item.description.isEmpty {
                                        Text(item.description)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }

                                    Button {
                                        guard let url = URL(string: item.url) else { return }
                                        pressedID = item.id
                                        UIApplication.shared.open(url) { _ in
                                            DispatchQueue.main.async {
                                                pressedID = nil
                                            }
                                        }
                                    } label: {
                                        Label("TẢI DNS ANTI", systemImage: "arrow.down.circle.fill")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                            .frame(maxWidth: .infinity, minHeight: 52)
                                    }
                                    .buttonStyle(.plain)
                                    .techButtonChrome()
                                    .foregroundStyle(AppTheme.accent)
                                    .background(
                                        Color(uiColor: .secondarySystemBackground).opacity(0.76),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    )
                                    .techBorder(
                                        enabled: appearance.technologyBorderEnabled,
                                        color: appearance.resolvedBorderColor,
                                        cornerRadius: 16,
                                        width: max(appearance.buttonBorderWidth, 1)
                                    )
                                    .scaleEffect(pressedID == item.id ? 0.975 : 1)
                                }
                            }
                        }
                    }

                    Button {
                        Task { await dnsFetcher.refresh() }
                    } label: {
                        Label("LÀM MỚI DANH SÁCH DNS", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.bordered)

                    TechSurface(cornerRadius: 20) {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("Lưu ý", systemImage: "info.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AppTheme.accent)
                            Text("iOS luôn yêu cầu người dùng xác nhận khi cài hồ sơ cấu hình. Ứng dụng chỉ mở link DNS do Web Admin cung cấp.")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle("Chức Năng AT")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await dnsFetcher.refresh()
        }
    }
}

// MARK: - 4. ContentView
struct ContentView: View {
    @Environment(\.appLanguage)       private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @EnvironmentObject private var repositoryStore: PackageRepositoryStore
    @EnvironmentObject private var repositoryPatchStore: PatchProjectStore
    @State private var tabNavigation: AppTabNavigationState
    @AppStorage(FeatureVisibility.cleanerStorageKey)    private var cleanerEnabled    = true
    @AppStorage(FeatureVisibility.wallpapersStorageKey) private var wallpapersEnabled = true
    @StateObject private var authManager = KeyAuthManager()
    @ObservedObject private var runtimeConfig = AppRuntimeConfig.shared
    @ObservedObject private var appearance = AppearanceSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showReentryAnimation = false
    @State private var hasEnteredBackground = false

    init() {
#if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        let restored = AppTabNavigationStore.load()
        _tabNavigation = State(initialValue: args.contains("--simulate-patch-tab")
            ? AppTabNavigationState(selectedTab: AppSection.files.rawValue)
            : (restored ?? AppTabNavigationState()))
#else
        _tabNavigation = State(initialValue: AppTabNavigationStore.load() ?? AppTabNavigationState())
#endif
    }

    var body: some View {
        ZStack {
            Group {
                if horizontalSizeClass == .regular { regularLayout } else { compactLayout }
            }
            .tint(appearance.resolvedGlobalAccent)
            .imageScale(.small)
            .opacity(appearance.globalOpacity)
            .onChange(of: patchDraftCoordinator.request?.id) {
                if $0 != nil { tabNavigation.select(AppSection.patches.rawValue) }
            }
            .onChange(of: patchDraftCoordinator.importRequest?.id) {
                if $0 != nil { tabNavigation.select(AppSection.patches.rawValue) }
            }
            .onChange(of: cleanerEnabled)    { _ in tabNavigation.reconcileSelection(with: featureVisibility) }
            .onChange(of: wallpapersEnabled) { _ in tabNavigation.reconcileSelection(with: featureVisibility) }
            .onChange(of: tabNavigation) { newState in
                // Persist every navigation mutation immediately; this covers tab
                // selection, tab renames, closes, and file navigation changes.
                AppTabNavigationStore.save(newState)
            }

            FluxStatusNotificationBanner()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 10)
                .padding(.trailing, 12)
                .zIndex(9_000)
                .allowsHitTesting(false)

            if authManager.isMaintenanceMode {
                MaintenanceView(config: AppRuntimeConfig.shared)
                    .transition(.opacity)
                    .zIndex(1000)
            } else if authManager.isExitingApp {
                MaintenanceView(config: AppRuntimeConfig.shared)
                    .transition(.opacity)
                    .zIndex(1000)
            } else if !authManager.isAuthorized {
                KeyActivationView(authManager: authManager).transition(.opacity).zIndex(999)
            }

            if authManager.isActivationTransitioning {
                LicenseActivationTransitionView()
                    .transition(.opacity)
                    .zIndex(2_000)
            }

            if showReentryAnimation {
                AppReentryAnimationView()
                    .transition(.opacity)
                    .zIndex(2_100)
            }
        }
        .repositoryStorePresentation(repositoryStore, patchStore: repositoryPatchStore)
        .onAppear {
            tabNavigation.reconcileSelection(with: featureVisibility)
            AppTabNavigationStore.save(tabNavigation)
            AutoPatchEngine.shared.configure(store: repositoryPatchStore)
            AutoPatchEngine.shared.trigger()
            Task { @MainActor in
                let loaded = await runtimeConfig.refresh()
                guard loaded else {
                    authManager.leaveMaintenanceMode()
                    authManager.verifyKey()
                    return
                }
                if runtimeConfig.maintenanceMode {
                    authManager.enterMaintenanceMode()
                    tabNavigation.select(AppSection.home.rawValue)
                } else {
                    authManager.leaveMaintenanceMode()
                    authManager.verifyKey()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .inactive, .background:
                hasEnteredBackground = phase == .background
                // Flush the lightweight UI snapshot at lifecycle boundaries.
                AppTabNavigationStore.save(tabNavigation)
            case .active:
                Task { @MainActor in
                    let loaded = await runtimeConfig.refresh()
                    guard loaded else { return }
                    if runtimeConfig.maintenanceMode {
                        authManager.enterMaintenanceMode()
                        tabNavigation.select(AppSection.home.rawValue)
                    } else if authManager.isMaintenanceMode {
                        authManager.leaveMaintenanceMode()
                        authManager.verifyKey()
                    }
                }

                guard hasEnteredBackground else { break }
                hasEnteredBackground = false
                guard appearance.animationsEnabled else { return }
                showReentryAnimation = true
                let duration = max(0.18, 0.46 * appearance.animationDurationMultiplier)
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    guard !hasEnteredBackground else { return }
                    showReentryAnimation = false
                }
            default:
                break
            }
        }
        .animation(
            appearance.animationsEnabled
                ? .easeInOut(duration: 0.30 * appearance.animationDurationMultiplier)
                : nil,
            value: showReentryAnimation
        )
        .animation(.easeInOut(duration: 0.38), value: authManager.isAuthorized)
        .animation(.easeInOut(duration: 0.38), value: authManager.isMaintenanceMode)
        .preferredColorScheme(appearance.appThemeMode.swiftUIScheme)
    }

    private var allowedSections: [AppSection] {
        if authManager.isMaintenanceMode {
            return [.home]
        }
        var s: [AppSection] = [.home, .at, .settings]
        if authManager.isPatchVisible { s.insert(.patches, at: 1) }
        return s
    }

    private var compactLayout: some View {
        TabView(selection: tabSelection) {
            ForEach(featureVisibility.visibleSections.filter { allowedSections.contains($0) }) { section in
                sectionContent(section)
                    .tabItem { CompactTabLabel(title: language.text(section.titleKey), systemImage: section.systemImage) }
                    .tag(section.rawValue)
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List {
                ForEach(featureVisibility.visibleSections.filter { allowedSections.contains($0) }) { section in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                            tabNavigation.select(section.rawValue)
                        }
                    } label: {
                        Label(language.text(section.titleKey), systemImage: section.systemImage)
                            .fontWeight(section.rawValue == tabNavigation.selectedTab ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).techButtonChrome()
                    .listRowBackground(
                        section.rawValue == tabNavigation.selectedTab
                            ? AppTheme.accent.opacity(0.14) : Color.clear)
                }
            }
            // REQ 6: no "3105" title
            .navigationTitle("")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            sectionContent(selectedVisibleSection).id(selectedVisibleSection.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        TechPageChrome {
            switch section {
            case .home:
                DashboardView(
                    cleanerEnabled: $cleanerEnabled,
                    wallpapersEnabled: $wallpapersEnabled,
                    wallpapersSupported: wallpapersSupported
                )
            case .files:      AppDataBrowserView(tabSession: filesTabSession)
            case .patches:    PatchProjectsView()
            case .cleaner:    CleanerView()
            case .wallpapers: WallpaperLabView()
            case .settings:   SettingsView(showsDoneButton: false)
            case .at:         ATView()
            }
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { tabNavigation.selectedTab },
            set: {
                tabNavigation.select($0)
            }
        )
    }
    private var filesTabSession: Binding<FilesTabSession> {
        Binding(get: { tabNavigation.filesTabs }, set: { tabNavigation.setFilesTabs($0) })
    }
    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(cleanerEnabled: cleanerEnabled,
                          wallpapersEnabled: wallpapersEnabled,
                          wallpapersSupported: wallpapersSupported)
    }
    private var wallpapersSupported: Bool {
        WallpaperFeatureSupportPolicy.isSupported(major: AppInfo.versionTuple.major)
    }
    private var selectedVisibleSection: AppSection {
        guard let s = AppSection(rawValue: tabNavigation.selectedTab),
              allowedSections.contains(s), featureVisibility.isVisible(s) else { return .home }
        return s
    }
}

// MARK: - 5. Tab label
private struct CompactTabLabel: View {
    let title: String; let systemImage: String
    @ViewBuilder var body: some View {
        if let img = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )?.withRenderingMode(.alwaysTemplate) {
            Image(uiImage: img)
        } else {
            Image(systemName: systemImage).font(.system(size: 17, weight: .medium))
        }
        Text(title)
    }
}

private extension AppSection {
    var titleKey: String {
        switch self {
        case .home:       return "tab.home"
        case .files:      return "tab.files"
        case .patches:    return "tab.patches"
        case .cleaner:    return "tab.cleaner"
        case .wallpapers: return "tab.wallpapers"
        case .settings:   return "settings.title"
        case .at:          return "tab.at"
        }
    }
    var systemImage: String {
        switch self {
        case .home:       return "house.fill"
        case .files:      return "folder.fill"
        case .patches:    return "shippingbox.fill"
        case .cleaner:    return "sparkles"
        case .wallpapers: return "photo.on.rectangle.angled"
        case .settings:   return "gearshape.fill"
        case .at:          return "wand.and.stars"
        }
    }
}

// MARK: - 6. LoopingVideoPlayer
/// Continuous AVPlayerLooper-backed playback for the animated anime background.
/// The player is owned by the UIKit view so SwiftUI layout updates never pause it.
struct LoopingVideoPlayer: UIViewRepresentable {
    let urlString: String

    final class PlayerView: UIView {
        var player: AVQueuePlayer?
        var playerLooper: AVPlayerLooper?
        var playerLayer: AVPlayerLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer?.frame = bounds
        }

        deinit {
            player?.pause()
            playerLooper?.disableLooping()
            playerLayer?.player = nil
        }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false

        guard let url = URL(string: urlString) else { return view }

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true

        let looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds

        view.player = player
        view.playerLooper = looper
        view.playerLayer = layer
        view.layer.insertSublayer(layer, at: 0)

        // Animated mode must remain continuously active. SwiftUI updates only resize
        // the layer; they never call pause(), seek(), or recreate the player.
        player.play()
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer?.frame = uiView.bounds
        // Deliberately do not pause/restart here. SwiftUI can update this representable
        // frequently while the AVPlayer continues rendering frames uninterrupted.
    }
}

// MARK: - 7. PatchGuideModal (unchanged)
struct PatchGuideModal: View {
    @Binding var isPresented: Bool
    private let guideSteps: [(String, String)] = [
        ("1. Mở Tab", "Vào tab, bấm nút + và chọn Tạo mới."),
        ("2. Nhập Thông Tin", "Nhập tên dự án và bundle identifier của ứng dụng đích. Có thể đặt mật khẩu."),
        ("3. Tạo Workspace", "Bấm Xong để tạo dự án và workspace có thể chỉnh sửa trong Tệp → Workspace → Patches."),
        ("4. Đặt File Thay Thế", "Tạo đúng cây đường dẫn đích rồi đặt file thay thế vào vị trí tương ứng bên trong folder bundle."),
        ("5. Áp Dụng", "Bấm Áp Dụng để đồng bộ workspace vào gói .3105 đã mã hóa và ghi vào container ứng dụng."),
        ("6. Khôi Phục", "Bấm Khôi phục file gốc để trả lại trạng thái ban đầu trước khi áp dụng."),
        ("Lưu Ý Quan Trọng", "Đóng ứng dụng đích trong lúc áp dụng. Không đổi tên folder bundle. Chỉ dùng với ứng dụng thuộc sở hữu của bạn.")
    ]
    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
                .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPresented = false } }
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(Color(red: 0.18, green: 0.52, blue: 1.0))
                            .font(.system(size: 18, weight: .semibold))
                        Text("Hướng Dẫn")
                            .font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPresented = false }
                    } label: {
                        ZStack {
                            Circle().fill(Color.white.opacity(0.1)).frame(width: 30, height: 30)
                            Text("×").font(.system(size: 20, weight: .medium)).foregroundColor(.white)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
                Divider().background(Color.white.opacity(0.08))
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(Array(guideSteps.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .top, spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(idx == guideSteps.count - 1
                                              ? Color.orange.opacity(0.18)
                                              : Color(red: 0.18, green: 0.52, blue: 1.0).opacity(0.15))
                                        .frame(width: 30, height: 30)
                                    Image(systemName: idx == guideSteps.count - 1
                                          ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(idx == guideSteps.count - 1
                                                         ? .orange
                                                         : Color(red: 0.18, green: 0.52, blue: 1.0))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(step.0).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                                    Text(step.1).font(.system(size: 12))
                                        .foregroundColor(Color(white: 0.65))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(12)
                            .background(Color(red: 0.10, green: 0.12, blue: 0.18).opacity(0.7))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.clear, lineWidth: 0))
                        }
                    }
                    .padding(16)
                }
            }
            .background(ZStack {
                Color(red: 0.06, green: 0.07, blue: 0.11)
                GridBackgroundView(spacing: 22, lineColor: Color.white.opacity(0.03))
            })
            .cornerRadius(24)
            .overlay(RoundedRectangle(cornerRadius: 24)
                .stroke(Color.clear, lineWidth: 0))
            .shadow(color: Color(red: 0.18, green: 0.52, blue: 1.0).opacity(0.18), radius: 30)
            .padding(.horizontal, 16).padding(.vertical, 40)
            .frame(maxHeight: UIScreen.main.bounds.height * 0.75)
        }
    }
}

// MARK: - 8. Home cover image
struct HomeCoverSection: View {
    private let imageURL = URL(
        string: "https://www.image2url.com/r2/default/files/1790007520502-b6c3841b-1960-41fc-9ee2-76d4c3d44358.jpg"
    )!
    @State private var appear = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20).fill(Color.black)
            homeCover
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.clear, lineWidth: 0)
        }
        .frame(height: 210)
        .shadow(color: Color(red: 0.18, green: 0.52, blue: 1.0).opacity(0.22), radius: 18, y: 6)
        .scaleEffect(appear ? 1.0 : 0.96).opacity(appear ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.80).delay(0.08)) { appear = true }
        }
    }

    @ViewBuilder
    private var homeCover: some View {
        if let cachedURL = AssetPreloadService.cachedURL(key: "home.cover"),
           let cachedImage = UIImage(contentsOfFile: cachedURL.path) {
            Image(uiImage: cachedImage)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 20))
        } else {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else if phase.error != nil {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - 9. PatchDownloadBanner (REQ 2 — top-right, persistent, all pages)
struct PatchDownloadBannerEntry: Identifiable {
    let id: String; let title: String; var status: BannerStatus
    enum BannerStatus { case downloading, done, failed }
}

@MainActor
final class PatchDownloadBannerCoordinator: ObservableObject {
    static let shared = PatchDownloadBannerCoordinator()
    private init() {}
    @Published var entries:   [PatchDownloadBannerEntry] = []
    @Published var isVisible: Bool = false
    private var hideTask: Task<Void, Never>?

    func show(entries: [PatchDownloadBannerEntry]) {
        self.entries = entries
        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) { isVisible = true }
        scheduleHide()
    }
    func update(id: String, status: PatchDownloadBannerEntry.BannerStatus) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = status; scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        let allDone = entries.allSatisfy { if case .downloading = $0.status { return false }; return true }
        let delay: TimeInterval = allDone ? 3.5 : 8.0
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.45)) { isVisible = false }
            try? await Task.sleep(nanoseconds: 600_000_000)
            entries = []
        }
    }
    func dismiss() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.35)) { isVisible = false }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            entries = []
        }
    }
}

/// REQ 2: Placed top-LEFT across all pages, persistent running status
struct PatchDownloadBanner: View {
    @ObservedObject private var coordinator = PatchDownloadBannerCoordinator.shared
    @State private var expand = false

    private var doneCount: Int { coordinator.entries.filter { if case .done    = $0.status { return true }; return false }.count }
    private var failCount: Int { coordinator.entries.filter { if case .failed  = $0.status { return true }; return false }.count }
    private var isRunning: Bool { coordinator.entries.contains { if case .downloading = $0.status { return true }; return false } }

    var body: some View {
        if coordinator.isVisible && !coordinator.entries.isEmpty {
            HStack {
                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 7) {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { expand.toggle() }
                    } label: {
                        HStack(spacing: 9) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.cyan.opacity(0.28), Color.blue.opacity(0.10)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 28, height: 28)

                                if isRunning {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.cyan)
                                        .scaleEffect(0.62)
                                } else {
                                    Image(systemName: failCount > 0
                                          ? "exclamationmark.triangle.fill"
                                          : "checkmark.seal.fill")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(failCount > 0 ? Color.orange : Color.green)
                                }
                            }

                            VStack(alignment: .trailing, spacing: 1) {
                                Text(isRunning ? "DOWNLOAD • \(coordinator.entries.count) FILE" : "PATCH COMPLETE")
                                    .font(.system(size: 9, weight: .black, design: .rounded))
                                    .tracking(1.0)
                                    .foregroundStyle(.white.opacity(0.95))

                                Text(isRunning
                                     ? "Đang đồng bộ dữ liệu…"
                                     : "\(doneCount) thành công\(failCount > 0 ? " • \(failCount) lỗi" : "")")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.58))
                            }

                            Image(systemName: expand ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.cyan.opacity(0.9))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color(red: 0.03, green: 0.12, blue: 0.22).opacity(0.88),
                                                    Color(red: 0.02, green: 0.05, blue: 0.13).opacity(0.94)
                                                ],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(Color.clear, lineWidth: 0)
                        )
                        .shadow(color: Color.cyan.opacity(0.18), radius: 14, y: 5)
                    }
                    .buttonStyle(.plain).techButtonChrome()

                    if expand {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(coordinator.entries) { entry in
                                HStack(spacing: 8) {
                                    bannerIcon(entry.status)

                                    Text(entry.title)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    bannerLabel(entry.status)
                                }
                            }

                            Rectangle()
                                .fill(Color.cyan.opacity(0.12))
                                .frame(height: 1)

                            Button { coordinator.dismiss() } label: {
                                Label("Đóng", systemImage: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .buttonStyle(.plain).techButtonChrome()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(11)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(Color(red: 0.02, green: 0.07, blue: 0.15).opacity(0.93))
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(Color.clear, lineWidth: 0)
                        )
                        .shadow(color: Color.blue.opacity(0.16), radius: 16, y: 7)
                        .frame(width: 270)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                    }
                }
            }
            .padding(.trailing, 14)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            ))
        }
    }

    @ViewBuilder private func bannerIcon(_ status: PatchDownloadBannerEntry.BannerStatus) -> some View {
        switch status {
        case .downloading: ProgressView().progressViewStyle(.circular).tint(.cyan).scaleEffect(0.6).frame(width: 14, height: 14)
        case .done:        Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.green)
        case .failed:      Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(.red)
        }
    }
    @ViewBuilder private func bannerLabel(_ status: PatchDownloadBannerEntry.BannerStatus) -> some View {
        switch status {
        case .downloading: Text("Đang tải").font(.system(size: 9)).foregroundColor(.cyan)
        case .done:        Text("Đã thêm").font(.system(size: 9)).foregroundColor(.green)
        case .failed:      Text("Lỗi").font(.system(size: 9)).foregroundColor(.red)
        }
    }
}

// MARK: - 10. AutoPatchEngine (REQ 2 — continuous, tab-change & tap triggered)
@MainActor
final class AutoPatchEngine: ObservableObject {
    static let shared = AutoPatchEngine()

    @Published private(set) var isRunning = false
    @Published private(set) var hasCompleted = false
    @Published private(set) var completedCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var totalCount = 0

    private init() {}

    private var fetcher: OnlineFileFetcher { OnlineFileFetcher.shared }
    private weak var store: PatchProjectStore?
    private var fetchedFiles: [OnlineFileItem] = []

    func configure(store: PatchProjectStore) {
        self.store = store
    }

    func trigger() {
        guard !isRunning else { return }
        Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        guard !isRunning else { return }

        isRunning = true
        hasCompleted = false
        completedCount = 0
        failedCount = 0
        totalCount = 0
        defer { isRunning = false }

        // Refresh server manifest (cached / throttled, no bulk download)
        await fetcher.fetchServerFiles()

        guard fetcher.lastFetchSucceeded else {
            failedCount = 1
            hasCompleted = true
            log("auto-patch: manifest unavailable after retry; keeping local patches")
            return
        }

        fetchedFiles = fetcher.onlineFiles
        store?.refreshPresentation()
        totalCount = fetchedFiles.count
        hasCompleted = true
        log("auto-patch: synced manifest with \(fetchedFiles.count) patch(es)")
    }

}

// MARK: - 11. DashboardView
// REQ 1: Settings moved to the main navigation bar
// REQ 2: Banner top-RIGHT; tap-anywhere trigger
// REQ 5: GlobalBackground applied
// REQ 6: no "3105" / "About 3105" / "patch" text in UI labels
private struct DashboardView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appearance  = AppearanceSettings.shared
    @ObservedObject private var wallpaperPalette = DynamicWallpaperPalette.shared

    @State private var showDevInfo  = false
    @Binding var cleanerEnabled:    Bool
    @Binding var wallpapersEnabled: Bool
    let wallpapersSupported: Bool

    @AppStorage("saved_key")      private var savedKey:     String = ""
    @AppStorage("key_duration")   private var keyDuration:  String = ""
    @AppStorage("key_expiry")     private var keyExpiry:    String = ""
    @AppStorage("key_expiry_timestamp") private var keyExpiryTimestamp: Double = 0

    @State private var card1Appear  = false
    @State private var card2Appear  = false
    @State private var card3Appear  = false
    @State private var card4Appear  = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                // REQ 5: global background
                GlobalBackground()

                // REQ 2: persistent banner — top-RIGHT
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        PatchDownloadBanner()
                    }
                    Spacer()
                }
                .zIndex(100)
                .allowsHitTesting(true)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {

                        // Video
                        HomeCoverSection()
                            .padding(.horizontal, 20)
                            .opacity(card1Appear ? 1 : 0).offset(y: card1Appear ? 0 : 20)

                        // Device info card
                        deviceInfoCard
                            .opacity(card2Appear ? 1 : 0).offset(y: card2Appear ? 0 : 20)

                        // Key info card
                        keyInfoCard
                            .opacity(card3Appear ? 1 : 0).offset(y: card3Appear ? 0 : 20)

                        // NDM PROXY Icon
                        DeveloperInfoCard()
                        .padding(.horizontal, 20)
                        .opacity(card4Appear ? 1 : 0)
                        .offset(y: card4Appear ? 0 : 20)

                        Spacer(minLength: 24)
                    }
                    .padding(.vertical, 16)
                }
                .zIndex(1)

            }
            // REQ 6: no "3105" navigation title
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.12))  { card1Appear  = true }
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.20))  { card2Appear  = true }
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.28))  { card3Appear  = true }
                withAnimation(.spring(response: 0.50, dampingFraction: 0.80).delay(0.36))  { card4Appear  = true }
            }
        }
    }

    // MARK: Sub-views

    private var deviceInfoCard: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "applelogo").foregroundColor(.pink).frame(width: 24)
                Text("Model").foregroundColor(Color(white: 0.7)).fontWeight(.medium)
                Spacer()
                Text(AppInfo.displayMachineName).foregroundColor(.white).fontWeight(.bold)
            }
            HStack {
                Image(systemName: "iphone")
                    .foregroundColor(Color(red: 0.18, green: 0.52, blue: 1.0)).frame(width: 24)
                Text("Device").foregroundColor(Color(white: 0.7)).fontWeight(.medium)
                Spacer()
                Text("\(AppInfo.osVersion) (\(AppInfo.osBuild))").foregroundColor(.white).fontWeight(.bold)
            }
            Divider().background(Color.white.opacity(0.1))
            HStack {
                Image(systemName: "checkmark.shield").foregroundColor(.yellow).frame(width: 24)
                Text(language.text("settings.compatibility")).foregroundColor(Color(white: 0.7)).fontWeight(.medium)
                Spacer()
                Text(appState.isSupported ? "Thiết Bị Hỗ Trợ" : "Không hỗ trợ")
                    .foregroundStyle(appState.isSupported ? Color.green : Color.red).fontWeight(.semibold)
            }
        }
        .padding(20)
        .background(Color(red: 0.12, green: 0.12, blue: 0.18).opacity(appearance.dynamicOpacity))
        .cornerRadius(20)
        .techBorder(enabled: appearance.technologyBorderEnabled,
                    color: appearance.resolvedBorderColor,
                    cornerRadius: 20,
                    width: max(appearance.cardBorderWidth, 1.0))
        .padding(.horizontal, 20)
    }

    private var keyInfoCard: some View {
        // REQ 2: KeyInfoCard with masking + copy + eye toggle
        KeyInfoCard(
            savedKey:    savedKey,
            keyDuration: keyDuration,
            keyExpiry:   keyExpiry,
            expiryTimestamp: keyExpiryTimestamp,
            borderColor: appearance.resolvedBorderColor,
            bgOpacity:   appearance.dynamicOpacity,
            borderStyle: appearance.borderStyle
        )
        .padding(.horizontal, 20)
        .techBorder(enabled: appearance.technologyBorderEnabled,
                    color: appearance.resolvedBorderColor,
                    cornerRadius: 20,
                    width: max(appearance.cardBorderWidth, 1.0))
    }
    }

// MARK: - Lightweight app re-entry animation
private struct AppReentryAnimationView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.10)
                    .ignoresSafeArea()

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                appearance.resolvedBorderColor.opacity(0.10),
                                appearance.resolvedBorderColor.opacity(0.72),
                                appearance.resolvedBorderColor.opacity(0.10),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * 0.72, height: 2)
                    .rotationEffect(.degrees(-8))
                    .offset(x: sweep ? proxy.size.width * 0.95 : -proxy.size.width * 0.95)
                    .blur(radius: 0.5)

                Circle()
                    .stroke(Color.clear, lineWidth: 0)
                    .frame(width: min(proxy.size.width, proxy.size.height) * 0.34)
                    .scaleEffect(sweep ? 1.20 : 0.82)
                    .opacity(sweep ? 0 : 0.9)
            }
            .allowsHitTesting(false)
            .onAppear {
                let duration = max(0.16, 0.40 * appearance.animationDurationMultiplier)
                withAnimation(.easeOut(duration: duration)) { sweep = true }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shared futuristic page chrome
private struct TechPageChrome<Content: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
                .padding(5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(appearance.resolvedBorderColor.opacity(0.82))
                .frame(width: 88, height: 1.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(appearance.resolvedBorderColor.opacity(0.64))
                .frame(width: 88, height: 1.5)
                .allowsHitTesting(false)
        }
        .transition(
            appearance.animationsEnabled
                ? .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                )
                : .identity
        )
    }
}

// MARK: - Shared futuristic surfaces
struct TechSurface<Content: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    let cornerRadius: CGFloat
    @ViewBuilder let content: () -> Content

    init(cornerRadius: CGFloat = 18, @ViewBuilder content: @escaping () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content
    }

    var body: some View {
        content()
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(min(max(appearance.dynamicOpacity, 0.05), 1))
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .techBorder(enabled: appearance.technologyBorderEnabled,
                        color: appearance.resolvedBorderColor,
                        cornerRadius: cornerRadius,
                        width: max(appearance.cardBorderWidth, 1))
    }
}

private struct LicenseActivationTransitionView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @State private var pulse = false
    @State private var sweep = false
    @State private var coreScale = 0.35

    private var duration: Double {
        max(0.22, 0.72 * appearance.animationDurationMultiplier)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            GeometryReader { proxy in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)

                Circle()
                    .stroke(Color.clear, lineWidth: 0)
                    .frame(width: min(proxy.size.width, proxy.size.height) * 0.72,
                           height: min(proxy.size.width, proxy.size.height) * 0.72)
                    .scaleEffect(pulse ? 1.22 : 0.58)
                    .opacity(pulse ? 0 : 1)
                    .position(center)

                Circle()
                    .fill(RadialGradient(colors: [appearance.resolvedBorderColor.opacity(0.92), .clear],
                                         center: .center, startRadius: 1, endRadius: 120))
                    .frame(width: 240, height: 240)
                    .scaleEffect(coreScale)
                    .position(center)

                Rectangle()
                    .fill(LinearGradient(colors: [.clear, appearance.resolvedBorderColor, .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .shadow(color: appearance.resolvedBorderColor, radius: 14)
                    .offset(y: sweep ? proxy.size.height * 0.45 : -proxy.size.height * 0.45)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
                    .frame(width: min(proxy.size.width * 0.72, 520), height: 170)
                    .rotation3DEffect(.degrees(sweep ? 0 : 18), axis: (x: 1, y: 0, z: 0))
                    .scaleEffect(sweep ? 1.04 : 0.86)
                    .opacity(sweep ? 0 : 1)
                    .position(center)
            }

            VStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(appearance.resolvedBorderColor)
                    .shadow(color: appearance.resolvedBorderColor.opacity(0.8), radius: 14)
                Text("KEY ĐÃ XÁC THỰC")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.white)
            }
        }
        .onAppear {
            guard appearance.animationsEnabled else { return }
            withAnimation(.easeOut(duration: duration)) { pulse = true }
            withAnimation(.easeInOut(duration: duration * 0.9)) { sweep = true }
            withAnimation(.spring(response: duration * 0.72, dampingFraction: 0.72)) { coreScale = 1.0 }
        }
    }
}

// MARK: - 12. GridBackgroundView
struct GridBackgroundView: View {
    var spacing:   CGFloat = 25
    var lineWidth: CGFloat = 1
    var lineColor: Color   = Color.white.opacity(0.04)
    var body: some View {
        GeometryReader { g in
            Path { path in
                for x in stride(from: 0, through: g.size.width,  by: spacing) {
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: g.size.height))
                }
                for y in stride(from: 0, through: g.size.height, by: spacing) {
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.clear, lineWidth: 0)
        }
    }
}
