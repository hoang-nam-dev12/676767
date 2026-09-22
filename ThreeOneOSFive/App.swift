import SwiftUI
import UIKit
import AVFoundation

// MARK: - FluxCoreAudioPlayer (stream URL, loops forever, survives background)
// Req 3: Exposes isPlaying + stateChangedNotification for music button UI sync
final class FluxCoreAudioPlayer: ObservableObject {
    static let shared = FluxCoreAudioPlayer()
    private static let enabledStorageKey = "audio.background.enabled"

    /// Notification posted whenever isPlaying changes — observed by FloatingButtonViewController
    static let stateChangedNotification = Notification.Name("FluxCoreAudioPlayerStateChanged")

    private var player: AVPlayer?
    private var loopObserver: Any?

    @Published private(set) var isPlaying: Bool = false

    private let musicURL = URL(string: "https://www.image2url.com/r2/default/files/1790007348399-b69ab7ff-1a62-4dca-98f6-91c724c62e20.mp3")!

    private var resolvedMusicURL: URL {
        AssetPreloadService.cachedURL(key: "audio.background") ?? musicURL
    }

    private init() {
        // Playback itself starts only after the SwiftUI scene is created.
        // The persisted preference is read by shouldPlayOnLaunch.
        isPlaying = false
    }

    var shouldPlayOnLaunch: Bool {
        UserDefaults.standard.object(forKey: Self.enabledStorageKey) as? Bool ?? true
    }

    deinit {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
        }
    }

    func play() {
        guard !isPlaying else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        if player == nil {
            player = AVPlayer(url: resolvedMusicURL)
            player?.volume = 0.72
        }
        player?.seek(to: .zero)
        player?.play()

        // Loop forever
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.player?.seek(to: .zero)
            self?.player?.play()
        }

        isPlaying = true
        UserDefaults.standard.set(true, forKey: Self.enabledStorageKey)
        NotificationCenter.default.post(name: FluxCoreAudioPlayer.stateChangedNotification, object: nil)
    }

    func stop() {
        guard isPlaying else { return }
        player?.pause()
        if let obs = loopObserver {
            NotificationCenter.default.removeObserver(obs)
            loopObserver = nil
        }
        isPlaying = false
        UserDefaults.standard.set(false, forKey: Self.enabledStorageKey)
        NotificationCenter.default.post(name: FluxCoreAudioPlayer.stateChangedNotification, object: nil)
    }
}

/// Backward-compatible name used by SettingsView and older UI code.
/// The implementation is the same shared FluxCore audio player.
typealias ZHModzAudioPlayer = FluxCoreAudioPlayer

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @StateObject private var repositoryPatchStore = PatchProjectStore()
    @StateObject private var startupLoader = StartupResourceLoader()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.vietnamese.rawValue
    // Startup loading is intentionally blocking. The existing language onboarding
    // remains available through its store, but must not interrupt the required
    // loading -> license-key flow.
    @State private var showOnboarding = false
    @State private var startupReady = false
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        log("app: Duy Mạnh Store launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
        // Restore the user's last music preference instead of forcing playback.
        if FluxCoreAudioPlayer.shared.shouldPlayOnLaunch {
            FluxCoreAudioPlayer.shared.play()
        }
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .vietnamese
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appState)
                    .environmentObject(patchDraftCoordinator)
                    .environmentObject(fileOperationCoordinator)
                    .environmentObject(repositoryStore)
                    .environmentObject(repositoryPatchStore)
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .opacity(startupReady ? 1 : 0)
                    .allowsHitTesting(startupReady)

                if !startupReady {
                    StartupLoadingView(
                        loader: startupLoader,
                        onSkipFailedPatch: {
                            guard startupLoader.canSkipFailedPatch else { return }
                            startupLoader.skipFailedPatch()
                            withAnimation(.easeOut(duration: 0.45)) {
                                startupReady = true
                            }
                            appState.detectSupport()
                            checkForUpdate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                FloatingWindowManager.shared.show()
                            }
                        }
                    )
                        .transition(.opacity)
                        .zIndex(10_000)
                        .allowsHitTesting(true)
                }
            }
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                        AppUpdateChecker.dismiss(version: offer.version)
                    }
                )
            }
            .onAppear {
                guard !startupReady else { return }

                Task { @MainActor in
                    let ready = await startupLoader.start()
                    guard ready else { return }

                    withAnimation(.easeOut(duration: 0.45)) {
                        startupReady = true
                    }

                    appState.detectSupport()
                    checkForUpdate()

                    // Khởi động Floating Mod Menu sau khi màn hình blocking đã biến mất.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        FloatingWindowManager.shared.show()
                    }
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !showOnboarding else { return }
                appState.detectSupport()
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}


// MARK: - Startup resource gate
//
// This gate owns the launch contract:
// 1. initialize;
// 2. preload the selected anime asset;
// 3. refresh runtime configuration;
// 4. expose the main UI after essential resources are ready.
// Cloud patch discovery/import is intentionally deferred to the Patch screen.
//
// Progress is derived from completed real network/cache operations, not a timer.
@MainActor
final class StartupResourceLoader: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var status: String = "Đang khởi tạo Duy Mạnh Store..."
    @Published private(set) var detail: String = "Kiểm tra cấu hình ứng dụng"
    @Published private(set) var canSkipFailedPatch = false
    private var started = false

    /// Chỉ bật khi startup thất bại ở bước xác minh/đồng bộ Patch.
    /// Không tự động bỏ qua: người dùng phải bấm nút trong màn hình startup.
    func skipFailedPatch() {
        guard canSkipFailedPatch else { return }
        canSkipFailedPatch = false
        status = "Đã bỏ qua Patch lỗi"
        detail = "Mở giao diện chính mà không nạp Patch chưa sẵn sàng"
        progress = 1.0
    }
    func start() async -> Bool {
        guard !started else { return progress >= 1 }
        started = true
        // Startup intentionally loads only essential visual/UI assets.
        // Patch manifest/download/import is deferred until the Patch tab is opened.
        setProgress(
            0.02,
            status: "Đang khởi tạo Duy Mạnh Store...",
            detail: "Chuẩn bị bộ nhớ tạm và core engine"
        )

        setProgress(
            0.12,
            status: "Đang tải tài nguyên giao diện...",
            detail: "Icon, hình nền động và video cần thiết"
        )
        await AssetPreloadService.shared.preloadAll()

        let dynamicAssetResult = await DynamicAssetSyncService.shared.sync()
        if !dynamicAssetResult.failed.isEmpty {
            log("startup-assets: supplemental sync failures=\(dynamicAssetResult.failed.joined(separator: ","))")
        }

        setProgress(
            0.20,
            status: "Đang kiểm tra cấu hình...",
            detail: "Đọc trạng thái bảo trì từ máy chủ"
        )
        _ = await AppRuntimeConfig.shared.refresh()

        if AppRuntimeConfig.shared.maintenanceMode {
            setProgress(
                1.0,
                status: "Đang ở chế độ bảo trì",
                detail: "Chỉ mở Trang chủ theo cấu hình máy chủ"
            )
            return true
        }

        setProgress(
            0.78,
            status: "Đang chuẩn bị khu vực Patch...",
            detail: "Thư viện Patch sẽ được đọc khi bạn mở khu vực này"
        )

        // Không tải manifest và toàn bộ file .3105 trong startup gate. Việc đó
        // từng làm ứng dụng bị giữ ở màn hình mở đầu khi tunnel chậm hoặc một
        // patch tạm thời lỗi. AutoPatchEngine sẽ đồng bộ đúng một lần khi người
        // dùng mở khu vực Patch; thư viện cục bộ vẫn được kiểm tra ở trên.
        setProgress(
            0.88,
            status: "Patch cục bộ đã sẵn sàng",
            detail: "Patch cloud sẽ đồng bộ nền khi mở khu vực Patch"
        )

        setProgress(
            0.90,
            status: "Đang chuẩn bị nền...",
            detail: "Cache nền được chọn để mở giao diện nhanh"
        )
        await BackgroundAssetCache.preloadSelectedBackground()

        setProgress(
            0.96,
            status: "Đang hoàn tất môi trường...",
            detail: "Kiểm tra trạng thái cuối cùng của tài nguyên"
        )
        try? await Task.sleep(for: .milliseconds(120))

        setProgress(
            1.0,
            status: "Hoàn tất",
            detail: "Tài nguyên và Patch cần thiết đã sẵn sàng"
        )
        return true
    }

    private func setProgress(_ value: Double, status: String, detail: String) {
        progress = min(max(value, 0), 1)
        self.status = status
        self.detail = detail
    }
}

// MARK: - FLUXCORE Startup Loading UI (REQ 2)
struct StartupLoadingView: View {
    @ObservedObject var loader: StartupResourceLoader
    let onSkipFailedPatch: () -> Void

    private var percent: Int { Int((loader.progress * 100).rounded()) }

    // Patch synchronization is part of the launch gate, so the checklist
    // reflects the actual startup pipeline.
    private var currentPhase: StartupPhase {
        switch loader.progress {
        case 0..<0.12: return .initialize
        case 0.12..<0.20: return .assets
        case 0.20..<0.90: return .patches
        case 0.90..<1.0: return .finalize
        default: return .done
        }
    }

    enum StartupPhase { case initialize, assets, patches, finalize, done }
    enum PhaseRowState { case waiting, active, done }

    // Per-phase checklist shown in the card (REQ 2)
    private let phases: [(phase: StartupPhase, label: String, icon: String)] = [
        (.initialize, "Khởi tạo Duy Mạnh Store",  "cpu.fill"),
        (.assets,     "Tải giao diện & video cần thiết", "photo.stack.fill"),
        (.patches,    "Đồng bộ Patch cần thiết",          "arrow.down.circle.fill"),
        (.finalize,   "Hoàn tất môi trường ứng dụng", "checkmark.shield.fill"),
        (.done,       "Sẵn sàng khởi động",          "checkmark.seal.fill"),
    ]

    var body: some View {
        ZStack {
            GlobalBackground().ignoresSafeArea()
            Color.black.opacity(0.38).ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 20) {

                    // ── Duy Mạnh Store spinner + percent ────────────
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.accent.opacity(0.18))
                                .frame(width: 96, height: 96)
                                .blur(radius: 2)
                            Circle()
                                .stroke(Color.clear, lineWidth: 0)
                                .frame(width: 96, height: 96)
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(AppTheme.accent)
                                .scaleEffect(1.50)
                            Text("\(percent)%")
                                .font(.system(size: 14, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        HStack(spacing: 7) {
                            Circle()
                                .fill(AppTheme.accent)
                                .frame(width: 6, height: 6)
                                .shadow(color: AppTheme.accent.opacity(0.90), radius: 5)
                            Text("DUY MẠNH STORE")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundStyle(AppTheme.accent)
                        }
                    }

                    // ── Main status text ────────────────────────────────
                    VStack(spacing: 6) {
                        Text(loader.status)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text(loader.detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }

                    // ── Per-phase checklist (REQ 2 core requirement) ────
                    VStack(spacing: 0) {
                        ForEach(Array(phases.enumerated()), id: \.offset) { idx, row in
                            phaseRow(
                                label: row.label,
                                icon:  row.icon,
                                state: rowState(for: row.phase)
                            )
                            if idx < phases.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.06))
                                    .frame(height: 1)
                                    .padding(.leading, 42)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.clear, lineWidth: 0)
                    )

                    // ── Progress bar ────────────────────────────────────
                    VStack(spacing: 7) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [AppTheme.accent, Color.cyan],
                                        startPoint: .leading, endPoint: .trailing
                                    ))
                                    .frame(width: proxy.size.width * loader.progress)
                                    .animation(.linear(duration: 0.18), value: loader.progress)
                            }
                        }
                        .frame(height: 7)
                        HStack {
                            Text("DUY MẠNH STORE")
                            Spacer()
                            Text("\(percent)%")
                        }
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.40))

                        if loader.canSkipFailedPatch {
                            Button(action: onSkipFailedPatch) {
                                HStack(spacing: 6) {
                                    Image(systemName: "forward.fill")
                                        .font(.system(size: 9, weight: .bold))
                                    Text("Bỏ qua Patch lỗi")
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                }
                                .foregroundStyle(.white.opacity(0.82))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .accessibilityLabel("Bỏ qua Patch lỗi và vào ứng dụng")
                        }
                    }
                }

                .padding(.horizontal, 26)
                .padding(.vertical, 30)
                .frame(maxWidth: 560)
                .background {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(LinearGradient(
                            colors: [
                                Color.white.opacity(0.07),
                                Color.black.opacity(0.52),
                                Color.black.opacity(0.70)
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .background(.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                }
                .shadow(color: .black.opacity(0.50), radius: 36, y: 20)
                .padding(.horizontal, 20)
            }
        }
        .allowsHitTesting(loader.canSkipFailedPatch)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Đang tải tài nguyên Duy Mạnh Store")
        .accessibilityValue("\(percent) phần trăm")
    }

    // MARK: Phase row helpers

    private func rowState(for phase: StartupPhase) -> PhaseRowState {
        let order: [StartupPhase] = [.initialize, .assets, .patches, .finalize, .done]
        let ci = order.firstIndex(of: currentPhase) ?? 0
        let pi = order.firstIndex(of: phase) ?? 0
        if pi < ci { return .done }
        if pi == ci { return .active }
        return .waiting
    }

    @ViewBuilder
    private func phaseRow(label: String, icon: String, state: PhaseRowState) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(rowStateColor(state).opacity(state == .waiting ? 0.06 : 0.18))
                    .frame(width: 28, height: 28)
                Group {
                    switch state {
                    case .done:
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.green)
                    case .active:
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(AppTheme.accent)
                            .scaleEffect(0.55)
                    case .waiting:
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.32))
                    }
                }
            }
            .frame(width: 28, height: 28)

            Text(label)
                .font(.system(size: 12,
                              weight: state == .active ? .bold : .medium,
                              design: .rounded))
                .foregroundStyle(
                    state == .waiting
                        ? Color.white.opacity(0.32)
                        : Color.white.opacity(state == .done ? 0.58 : 0.92)
                )

            Spacer()

            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.green.opacity(0.75))
            case .active:
                Text("Đang xử lý")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)
            case .waiting:
                Text("Chờ")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func rowStateColor(_ state: PhaseRowState) -> Color {
        switch state {
        case .done:    return .green
        case .active:  return AppTheme.accent
        case .waiting: return .white
        }
    }
}


// MARK: - Local background cache
enum BackgroundAssetCache {
    private static let staticName = "startup-anime-background-static.mov"
    private static let dynamicName = "startup-anime-background-dynamic.mp4"
    private static let lightSkyName = "startup-light-sky-background.mp4"

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StartupAssets", isDirectory: true)
    }

    static func cachedURL(for key: String) -> URL? {
        if let generic = AssetPreloadService.cachedURL(
            key: {
                switch key {
                case "animeStatic": return "background.static"
                case "animeDynamic": return "background.dynamic"
                case "lightSky": return "background.lightSky"
                default: return key
                }
            }()
        ) {
            return generic
        }
        let name: String
        switch key {
        case "animeStatic":
            name = staticName
        case "animeDynamic":
            name = dynamicName
        case "lightSky":
            name = lightSkyName
        default:
            return nil
        }

        let url = cacheDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func preloadSelectedBackground() async {
        let mode = AppearanceSettings.shared.backgroundMode

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await downloadIfNeeded(
                    urlString: AppearanceSettings.BackgroundMode.animeDynamicVideoURL,
                    fileName: dynamicName
                )
            }
            group.addTask {
                await downloadIfNeeded(
                    urlString: AppearanceSettings.BackgroundMode.lightSkyVideoURL,
                    fileName: lightSkyName
                )
            }

            if mode == .animeStatic {
                group.addTask {
                    await downloadIfNeeded(
                        urlString: AppearanceSettings.BackgroundMode.animeStaticVideoURL,
                        fileName: staticName
                    )
                }
            }

            for await _ in group {}
        }
    }

    private static func downloadIfNeeded(urlString: String, fileName: String) async {
        guard let url = URL(string: urlString) else { return }

        let destination = cacheDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { return }

        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = true

            let (temporaryURL, response) = try await URLSession(configuration: configuration).download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            log("startup-assets: \(error.localizedDescription)")
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}


// MARK: - Remote App Runtime Configuration
struct MaintenanceButton: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let url: String
}

@MainActor
final class AppRuntimeConfig: ObservableObject {
    static let shared = AppRuntimeConfig()

    @Published private(set) var maintenanceMode = false
    @Published private(set) var maintenanceNotice = "Hệ thống đang bảo trì, vui lòng quay lại sau."
    @Published private(set) var maintenanceInterval: TimeInterval = 10
    @Published private(set) var maintenanceButtons: [MaintenanceButton] = []

    private var refreshTask: URLSessionDataTask?

    private init() {}

    func refresh() async -> Bool {
        refreshTask?.cancel()
        guard let url = URL(string: Self.endpoint) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }

            let envelope = try JSONDecoder().decode(RuntimeEnvelope.self, from: data)
            let value = envelope.value

            let validButtons = value.maintenanceButtons.filter { button in
                guard let components = URLComponents(string: button.url),
                      let scheme = components.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      !button.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return false
                }
                return true
            }

            maintenanceMode = value.maintenanceMode
            maintenanceNotice = value.maintenanceNotice
            maintenanceInterval = min(max(TimeInterval(value.maintenanceInterval), 1), 86400)
            maintenanceButtons = validButtons
            return true
        } catch is CancellationError {
            return false
        } catch {
            log("runtime-config: \(error.localizedDescription)")
            return false
        }
    }

    private static let endpoint = "https://appfluxcore.site/api/config.php?key=app_runtime"

    private struct RuntimeEnvelope: Decodable {
        let value: RuntimeValue
    }

    private struct RuntimeValue: Decodable {
        let maintenanceMode: Bool
        let maintenanceNotice: String
        let maintenanceInterval: Int
        let maintenanceButtons: [MaintenanceButton]

        enum CodingKeys: String, CodingKey {
            case maintenanceMode = "maintenance_mode"
            case maintenanceNotice = "maintenance_notice"
            case maintenanceInterval = "maintenance_interval"
            case maintenanceButtons = "maintenance_buttons"
        }
    }
}
