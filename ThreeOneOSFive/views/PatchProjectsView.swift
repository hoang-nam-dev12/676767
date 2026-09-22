import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CryptoKit

// MARK: - UTType policy (unchanged)
private enum PatchPackagePickerPolicy {
    static let packageType = UTType(filenameExtension: "3105") ?? .data
    static let allowedContentTypes: [UTType] = [packageType, .data]
    static let copiesSelectedDocument = true
}

// MARK: - Online file model (unchanged)
struct OnlineFileItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let filename: String
    let url: String
    let status: Bool
    let created_at: Int
    let sha256: String?
    let packageID: String?
    let game: String?
    let category: String?
    let password: String?
    let size: Int?

    init(
        id: String,
        title: String,
        filename: String,
        url: String,
        status: Bool,
        created_at: Int,
        sha256: String? = nil,
        packageID: String? = nil,
        game: String? = nil,
        category: String? = nil,
        password: String? = nil,
        size: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.url = url
        self.status = status
        self.created_at = created_at
        self.sha256 = sha256
        self.packageID = packageID
        self.game = game
        self.category = category
        self.password = password
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case id, title, filename, url, status, created_at, sha256
        case game, category, password, size
        case packageID = "package_id"
    }
}

// MARK: - Persisted server classification

/// Keeps the website's game/category choices attached to an imported package.
/// The .3105 package format predates these fields, so the classification must
/// be retained alongside the local library rather than inferred from its name.
private enum ServerPatchMetadataStore {
    struct Record: Codable, Hashable {
        let serverID: String
        let packageID: String?
        let title: String
        let filename: String
        let game: String
        let category: String
    }

    private final class MemoryCache: @unchecked Sendable {
        let lock = NSLock()
        var records: [Record]?
        var map: [String: String]?
    }

    private static let storageKey = "PatchProjects.serverMetadata.v1"
    private static let packageIDMapKey = "PatchProjects.serverPackageIDMap.v1"
    private static let memoryCache = MemoryCache()

    private static func loadMap() -> [String: String] {
        memoryCache.lock.lock()
        defer { memoryCache.lock.unlock() }
        if let map = memoryCache.map {
            return map
        }
        let map = UserDefaults.standard.dictionary(forKey: packageIDMapKey) as? [String: String] ?? [:]
        memoryCache.map = map
        return map
    }

    private static func saveMapping(serverID: String, packageID: String) {
        var map = loadMap()
        map[serverID] = packageID
        map[packageID] = serverID
        memoryCache.lock.lock()
        memoryCache.map = map
        memoryCache.lock.unlock()
        UserDefaults.standard.set(map, forKey: packageIDMapKey)
    }

    static func replace(with files: [OnlineFileItem]) {
        let previous = Dictionary(uniqueKeysWithValues: load().map { ($0.serverID, $0) })
        let map = loadMap()
        let records = files.compactMap { file -> Record? in
            guard let fresh = record(from: file) else { return nil }
            if let directID = normalizedPackageID(file.packageID) {
                return replacingPackageID(in: fresh, with: directID)
            }
            if let associatedID = previous[file.id]?.packageID ?? map[file.id] {
                return replacingPackageID(in: fresh, with: associatedID)
            }
            return fresh
        }
        save(records)
    }

    static func associate(_ file: OnlineFileItem, packageID: UUID) {
        let idStr = packageID.uuidString.lowercased()
        saveMapping(serverID: file.id, packageID: idStr)
        guard let fresh = record(from: file) else { return }
        var records = load()
        let associated = replacingPackageID(
            in: fresh,
            with: idStr
        )
        if let index = records.firstIndex(where: { $0.serverID == file.id }) {
            records[index] = associated
        } else {
            records.append(associated)
        }
        save(records)
    }

    static func packageID(for file: OnlineFileItem) -> String? {
        if let existing = load().first(where: { $0.serverID == file.id })?.packageID {
            return existing
        }
        return loadMap()[file.id]
    }

    static func record(for item: PatchLibraryItem) -> Record? {
        let records = load()
        let packageID = item.summary.packageID.uuidString.lowercased()
        if let exact = records.first(where: { $0.packageID == packageID }) {
            return exact
        }

        let map = loadMap()
        if let serverID = map[packageID],
           let exact = records.first(where: { $0.serverID == serverID }) {
            return exact
        }

        var identities = Set<String>()
        identities.insert(normalizedIdentity(item.packageURL.deletingPathExtension().lastPathComponent))
        if let projectName = item.project?.name {
            identities.insert(normalizedIdentity(projectName))
        }
        identities.remove("")

        return records.first { record in
            let recordIdentities = [
                normalizedIdentity(record.title),
                normalizedIdentity(URL(fileURLWithPath: record.filename).deletingPathExtension().lastPathComponent)
            ]
            return recordIdentities.contains(where: identities.contains)
        }
    }

    static func displayTitle(for item: PatchLibraryItem) -> String {
        if let title = record(for: item)?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let projectName = item.project?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectName.isEmpty {
            return projectName
        }
        return item.packageURL.deletingPathExtension().lastPathComponent
    }

    private static func record(from file: OnlineFileItem) -> Record? {
        guard let game = normalizedGame(file.game),
              let category = PatchType.serverCategory(file.category) else {
            return nil
        }
        return Record(
            serverID: file.id,
            packageID: normalizedPackageID(file.packageID),
            title: file.title,
            filename: file.filename,
            game: game,
            category: categoryKey(category)
        )
    }

    private static func load() -> [Record] {
        memoryCache.lock.lock()
        defer { memoryCache.lock.unlock() }
        if let records = memoryCache.records {
            return records
        }
        let records: [Record]
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        } else {
            records = []
        }
        memoryCache.records = records
        return records
    }

    private static func save(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        memoryCache.lock.lock()
        memoryCache.records = records
        memoryCache.lock.unlock()
    }

    private static func replacingPackageID(in record: Record, with packageID: String) -> Record {
        Record(
            serverID: record.serverID,
            packageID: packageID,
            title: record.title,
            filename: record.filename,
            game: record.game,
            category: record.category
        )
    }

    private static func normalizedGame(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["all", "ff", "ffm", "capcut", "pubg", "lienquan", "locket"].contains(value) else {
            return nil
        }
        return value
    }

    private static func normalizedPackageID(_ raw: String?) -> String? {
        guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func categoryKey(_ category: PatchType) -> String {
        switch category {
        case .aim: return "aim"
        case .visual: return "visual"
        case .mod: return "mod"
        case .utility: return "utility"
        case .other: return "other"
        }
    }

    private static func normalizedIdentity(_ raw: String) -> String {
        String(
            raw.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map { Character($0) }
        ).lowercased()
    }
}

// MARK: - Online file fetcher
@MainActor
final class OnlineFileFetcher: ObservableObject {
    static let shared = OnlineFileFetcher()

    @Published var onlineFiles: [OnlineFileItem] = []
    @Published var isLoading: Bool = false
    @Published var downloadingIDs: Set<String> = []
    private(set) var lastFetchSucceeded = false
    private var localPackageIDByIdentity: [String: String] = [:]
    private var hasPreparedLocalIndex = false
    private var lastFetchDate: Date?
    private let minFetchInterval: TimeInterval = 600 // 10 minutes

    private lazy var manifestSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 35
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadRevalidatingCacheData
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    private var manifestURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PatchCloudManifestURL") as? String else {
            return nil
        }
        return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func fetchServerFiles(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let last = lastFetchDate, Date().timeIntervalSince(last) < minFetchInterval, !onlineFiles.isEmpty {
            log("online-files: skipped fetch, cached manifest still fresh")
            return
        }

        guard let baseURL = manifestURL else {
            onlineFiles = []
            lastFetchSucceeded = false
            log("online-files: PatchCloudManifestURL is missing or invalid")
            return
        }
        isLoading = true
        lastFetchSucceeded = false
        defer { isLoading = false }

        for attempt in 1...3 {
            if Task.isCancelled { return }
            do {
                guard var components = URLComponents(
                    url: baseURL,
                    resolvingAgainstBaseURL: false
                ) else {
                    throw URLError(.badURL)
                }
                var queryItems = components.queryItems ?? []
                queryItems.removeAll { $0.name == "_sync" }
                queryItems.append(
                    URLQueryItem(
                        name: "_sync",
                        value: "\(Int(Date().timeIntervalSince1970))-\(attempt)"
                    )
                )
                components.queryItems = queryItems
                guard let requestURL = components.url else {
                    throw URLError(.badURL)
                }

                var request = URLRequest(
                    url: requestURL,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 20
                )
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")

                let (data, response) = try await manifestSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let decoded = try JSONDecoder().decode([OnlineFileItem].self, from: data)
                var seenPackageIDs = Set<String>()
                let activeFiles = decoded
                    .filter { $0.status }
                    .sorted { $0.created_at > $1.created_at }
                    .filter { file in
                        guard let rawID = file.packageID,
                              let packageID = UUID(uuidString: rawID)?.uuidString.lowercased() else {
                            return true
                        }
                        return seenPackageIDs.insert(packageID).inserted
                    }
                ServerPatchMetadataStore.replace(with: activeFiles)
                onlineFiles = activeFiles
                lastFetchSucceeded = true
                lastFetchDate = Date()
                log("online-files: synced \(activeFiles.count) patch(es) from server")
                return
            } catch is CancellationError {
                return
            } catch {
                log("online-files: attempt \(attempt)/3 failed – \(error.localizedDescription)")
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(450 * attempt))
                }
            }
        }
    }

    /// Tải một patch đơn lẻ khi người dùng yêu cầu (on-demand download)
    func downloadSinglePatch(file: OnlineFileItem, store: PatchProjectStore) async -> Bool {
        guard !downloadingIDs.contains(file.id) else { return false }
        downloadingIDs.insert(file.id)
        defer { downloadingIDs.remove(file.id) }

        log("single-download: starting download for \(file.title) (\(file.filename))")

        let deadline = Date().addingTimeInterval(30)
        while store.isBusy && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }

        let ok = await synchronizePatch(file: file, store: store)
        if ok {
            log("single-download: successfully imported \(file.title)")
            store.reload()
        } else {
            log("single-download: failed to import \(file.title)")
        }
        return ok
    }

    func recordSuccessfulImport(_ file: OnlineFileItem, packageID: UUID?) {
        if let packageID {
            ServerPatchMetadataStore.associate(file, packageID: packageID)
        }
        markServerManaged(file)
    }

    /// Synchronizes every active server patch for the launch gate.
    ///
    /// A package already present in the local library is considered satisfied.
    /// Otherwise a validated per-server-id cache entry is reused before any
    /// network request is attempted. Downloads are atomic and, when the API
    /// supplies sha256, checksum verified before import.
    func preloadAllPatches(
        files: [OnlineFileItem],
        store: PatchProjectStore,
        progress: @escaping @MainActor (Int, Int, Int, String) -> Void,
        itemResult: @escaping @MainActor (OnlineFileItem, Bool) -> Void = { _, _ in }
    ) async -> Bool {
        // Remove packages no longer present on the server before building the
        // local lookup index. Otherwise the index can retain a just-deleted
        // package and incorrectly skip its replacement.
        let removedMissingPackages = await reconcileMissingServerPackages(manifest: files)
        if removedMissingPackages {
            store.reload()
        }
        guard !files.isEmpty else { return true }

        let localItems = store.items
        let localNames = Set(localItems.map { item in
            var identities = [item.packageURL.deletingPathExtension().lastPathComponent]
            if let project = item.project {
                identities.append(project.name)
            }
            return identities.map(Self.normalizedLocalIdentity)
        }.flatMap { $0 })
        let localPackageIDs = Set(localItems.map {
            $0.summary.packageID.uuidString.lowercased()
        })
        var packageIDByIdentity: [String: String] = [:]
        for item in localItems {
            let packageID = item.summary.packageID.uuidString.lowercased()
            let identities = [
                item.packageURL.deletingPathExtension().lastPathComponent,
                item.project?.name ?? ""
            ].map(Self.normalizedLocalIdentity).filter { !$0.isEmpty }
            for identity in identities where packageIDByIdentity[identity] == nil {
                packageIDByIdentity[identity] = packageID
            }
        }

        var knownLocalNames = localNames
        var knownLocalPackageIDs = localPackageIDs
        localPackageIDByIdentity = packageIDByIdentity
        hasPreparedLocalIndex = true

        var completed = 0
        var failed = 0

        for file in files {
            if Task.isCancelled { return false }

            progress(completed, files.count, failed, file.title)

            let ok: Bool
            if isAlreadyInstalled(
                file: file,
                localNames: knownLocalNames,
                localPackageIDs: knownLocalPackageIDs
            ) {
                log("startup-patch: local package found, skip download – \(file.title)")
                ok = true
            } else {
                ok = await synchronizePatch(file: file, store: store)
            }

            if ok {
                completed += 1
                markServerManaged(file)
                knownLocalNames.insert(Self.normalizedLocalIdentity(file.title))
                knownLocalNames.insert(Self.normalizedLocalIdentity(file.filename))
                if let packageID = resolvedPackageID(for: file) {
                    knownLocalPackageIDs.insert(packageID)
                }
            } else {
                failed += 1
            }

            itemResult(file, ok)
            progress(completed, files.count, failed, file.title)
        }

        // Launch readiness is an integrity gate: exposing the UI after only
        // some active server packages were imported would violate the startup
        // contract and leave patch state ambiguous.
        return !Task.isCancelled && failed == 0
    }

    private func reconcileMissingServerPackages(manifest: [OnlineFileItem]) async -> Bool {
        guard !manifest.isEmpty else { return false }
        let key = "PatchProjects.serverManagedPackageIDs.v1"
        let previous = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard !previous.isEmpty else { return false }

        let current = Set(manifest.compactMap { file in
            normalizedPackageID(file.packageID)
                ?? normalizedPackageID(ServerPatchMetadataStore.packageID(for: file))
        })
        guard !current.isEmpty else {
            return false
        }

        let missing = previous.subtracting(current)
        guard !missing.isEmpty else {
            return false
        }

        let localItems = PatchProjectLibrary.load()
        var removedAny = false
        for item in localItems {
            let packageID = item.summary.packageID.uuidString.lowercased()
            guard missing.contains(packageID) else { continue }

            do {
                if let receipt = DevicePatchService.latestAppliedReceipt(projectID: item.id) {
                    try DevicePatchService.restore(receipt: receipt)
                }
                try PatchProjectLibrary.delete(item)
                removedAny = true
                log("patch-sync: server source disappeared; local package deleted and patch disabled – \(packageID)")
            } catch {
                log("patch-sync: failed to remove missing package \(packageID): \(error.localizedDescription)")
            }
        }

        let remaining = previous.subtracting(missing)
        persistManagedPackageIDs(remaining, key: key)
        return removedAny
    }

    private func removeManagedPackage(for file: OnlineFileItem) {
        guard let packageID = resolvedPackageID(for: file) else { return }
        guard let item = PatchProjectLibrary.load().first(where: {
            $0.summary.packageID.uuidString.lowercased() == packageID
        }) else { return }

        do {
            if let receipt = DevicePatchService.latestAppliedReceipt(projectID: item.id) {
                try DevicePatchService.restore(receipt: receipt)
            }
            try PatchProjectLibrary.delete(item)
            log("patch-sync: source not found; local package deleted and patch disabled – \(packageID)")
        } catch {
            log("patch-sync: failed to disable missing package \(packageID): \(error.localizedDescription)")
        }
    }

    private func markServerManaged(_ file: OnlineFileItem) {
        guard let packageID = resolvedPackageID(for: file) else { return }
        if let uuid = UUID(uuidString: packageID) {
            ServerPatchMetadataStore.associate(file, packageID: uuid)
        }
        let key = "PatchProjects.serverManagedPackageIDs.v1"
        var ids = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        ids.insert(packageID)
        persistManagedPackageIDs(ids, key: key)

        if let checksum = normalizedSHA256(file.sha256) {
            let checksumKey = "PatchProjects.serverManagedSHA256.v1"
            var checksums = UserDefaults.standard.dictionary(forKey: checksumKey) as? [String: String] ?? [:]
            checksums[packageID] = checksum
            UserDefaults.standard.set(checksums, forKey: checksumKey)
        }
    }

    private func resolvedPackageID(for file: OnlineFileItem) -> String? {
        if let direct = normalizedPackageID(file.packageID)
            ?? normalizedPackageID(ServerPatchMetadataStore.packageID(for: file)) {
            return direct
        }

        let serverIdentities = Set([
            Self.normalizedLocalIdentity(file.title),
            Self.normalizedLocalIdentity(
                URL(fileURLWithPath: file.filename).deletingPathExtension().lastPathComponent
            )
        ].filter { !$0.isEmpty })

        if let packageID = serverIdentities.compactMap({ localPackageIDByIdentity[$0] }).first,
           let uuid = UUID(uuidString: packageID) {
            ServerPatchMetadataStore.associate(file, packageID: uuid)
            return packageID
        }

        guard !hasPreparedLocalIndex,
              let local = PatchProjectLibrary.load().first(where: { item in
                  let localIdentities = [
                      Self.normalizedLocalIdentity(item.packageURL.deletingPathExtension().lastPathComponent),
                      Self.normalizedLocalIdentity(item.project?.name ?? "")
                  ]
                  return localIdentities.contains(where: serverIdentities.contains)
              }) else {
            return nil
        }

        ServerPatchMetadataStore.associate(file, packageID: local.summary.packageID)
        return local.summary.packageID.uuidString.lowercased()
    }

    private func persistManagedPackageIDs(_ ids: Set<String>, key: String) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }

    private func normalizedPackageID(_ raw: String?) -> String? {
        guard let raw, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func synchronizePatch(
        file: OnlineFileItem,
        store: PatchProjectStore
    ) async -> Bool {
        if let cached = cachedStartupPackageURL(for: file),
           validateCachedPackage(cached, expectedSHA256: file.sha256) {
            log("startup-patch: using local download cache – \(file.title)")
            return await importLocalPackage(
                cached,
                manifest: file,
                password: file.password,
                store: store,
                removeCacheAfterSuccess: true
            )
        }

        guard let url = URL(string: file.url.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https" else {
            log("startup-patch: invalid HTTPS URL – \(file.title)")
            return false
        }

        for attempt in 1...3 {
            do {
                let (tmp, response) = try await downloadSession.download(from: url)
                defer { try? FileManager.default.removeItem(at: tmp) }

                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                if http.statusCode == 404 || http.statusCode == 410 {
                    removeManagedPackage(for: file)
                    return false
                }
                guard (200..<300).contains(http.statusCode), isSafeRegularFile(tmp) else {
                    throw URLError(.badServerResponse)
                }

                if let expected = normalizedSHA256(file.sha256) {
                    guard try sha256(of: tmp) == expected else {
                        log("startup-patch: checksum mismatch – \(file.title)")
                        return false
                    }
                }

                let cacheURL = startupCacheURL(for: file)
                try FileManager.default.createDirectory(
                    at: startupCacheDirectory(),
                    withIntermediateDirectories: true
                )
                try atomicReplace(source: tmp, destination: cacheURL)

                return await importLocalPackage(
                    cacheURL,
                    manifest: file,
                    password: file.password,
                    store: store,
                    removeCacheAfterSuccess: true
                )
            } catch is CancellationError {
                return false
            } catch {
                log("startup-patch: \(file.title), attempt \(attempt)/3: \(error.localizedDescription)")
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(500 * attempt))
                }
            }
        }
        return false
    }

    private func importLocalPackage(
        _ packageURL: URL,
        manifest file: OnlineFileItem,
        password: String?,
        store: PatchProjectStore,
        removeCacheAfterSuccess: Bool
    ) async -> Bool {
        guard isSafeRegularFile(packageURL) else { return false }
        guard let data = try? Data(contentsOf: packageURL, options: .mappedIfSafe) else {
            return false
        }
        let packageID = try? PatchPackageCodec.inspect(data).packageID
        if let packageID {
            ServerPatchMetadataStore.associate(file, packageID: packageID)
        }
        let ok = await store.importPackageAndWait(
            data: data,
            password: password,
            timeout: 45
        )

        if ok, let packageID {
            ServerPatchMetadataStore.associate(file, packageID: packageID)
            markServerManaged(file)
        }

        if ok && removeCacheAfterSuccess {
            try? FileManager.default.removeItem(at: packageURL)
        }
        return ok
    }

    private func isAlreadyInstalled(
        file: OnlineFileItem,
        localNames: Set<String>,
        localPackageIDs: Set<String>
    ) -> Bool {
        if let packageID = resolvedPackageID(for: file),
           localPackageIDs.contains(packageID) {
            guard let expectedChecksum = normalizedSHA256(file.sha256) else {
                return true
            }
            let checksumKey = "PatchProjects.serverManagedSHA256.v1"
            let checksums = UserDefaults.standard.dictionary(forKey: checksumKey) as? [String: String] ?? [:]
            // An older app may have installed this package without persisting
            // its fingerprint. Treat that state as unknown and download once;
            // accepting it would incorrectly mark an outdated local package as
            // identical to the newest server revision.
            guard let installedChecksum = checksums[packageID] else { return false }
            return installedChecksum == expectedChecksum
        }

        let filename = normalizedPackageFilename(file.filename, fallbackURL: file.url)
        if localNames.contains(Self.normalizedLocalIdentity(filename)) {
            return true
        }

        let titleIdentity = Self.normalizedLocalIdentity(file.title)
        return !titleIdentity.isEmpty && localNames.contains(titleIdentity)
    }

    private nonisolated static func normalizedLocalIdentity(_ raw: String) -> String {
        String(
            raw.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map { Character($0) }
        ).lowercased()
    }

    private func normalizedPackageFilename(_ raw: String, fallbackURL: String) -> String {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = candidate.isEmpty
            ? (URL(string: fallbackURL)?.lastPathComponent ?? "Patch")
            : candidate
        return base.lowercased().hasSuffix(".3105") ? base : "\(base).3105"
    }

    private func startupCacheDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("StartupPatchCache.v1", isDirectory: true)
    }

    private func startupCacheURL(for file: OnlineFileItem) -> URL {
        let digest = SHA256.hash(data: Data(file.id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return startupCacheDirectory().appendingPathComponent("\(digest).3105")
    }

    private func cachedStartupPackageURL(for file: OnlineFileItem) -> URL? {
        let url = startupCacheURL(for: file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func validateCachedPackage(_ url: URL, expectedSHA256: String?) -> Bool {
        guard isSafeRegularFile(url) else { return false }
        guard let expected = normalizedSHA256(expectedSHA256) else { return true }
        return (try? sha256(of: url)) == expected
    }

    private func normalizedSHA256(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else {
            return nil
        }
        return value
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]) else { return false }
        return values.isRegularFile == true &&
               values.isSymbolicLink != true &&
               (values.fileSize ?? 0) > 0
    }

    private func atomicReplace(source: URL, destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }

        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)
    }

    private func waitUntilImportFinishes(
        store: PatchProjectStore,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !store.isBusy {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        return !store.isBusy
    }
}

// MARK: - Download All Patches state

/// Tracks the per-file progress of a batch download session.
struct PatchDownloadProgress: Identifiable {
    let id: String            // mirrors OnlineFileItem.id
    let title: String
    var fraction: Double      // 0.0 … 1.0
    var status: DownloadStatus

    enum DownloadStatus {
        case pending, downloading, importing, done, failed(String)
    }
}

private enum OnlinePatchDownloadError: LocalizedError {
    case invalidURL
    case insecureURL
    case badResponse
    case sizeMismatch
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL patch không hợp lệ"
        case .insecureURL: return "URL patch phải dùng HTTPS"
        case .badResponse: return "Server trả về phản hồi không hợp lệ"
        case .sizeMismatch: return "Kích thước file không khớp manifest"
        case .checksumMismatch: return "Checksum SHA-256 không khớp"
        }
    }
}

// MARK: - Download All Sheet

struct OnlineFilesSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var fetcher = OnlineFileFetcher()
    @ObservedObject var store: PatchProjectStore

    // Single-file state (existing behaviour)
    @State private var downloadingFileID: String?
    @State private var showSuccessToast = false

    // Batch download state (Feature 1)
    @State private var batchProgresses: [PatchDownloadProgress] = []
    @State private var isBatchRunning = false
    @State private var batchDoneCount = 0
    @State private var batchErrorCount = 0
    @State private var showBatchSummary = false

    // Auto-start: chỉ kích hoạt 1 lần ngay sau khi fetch xong
    @State private var autoStarted = false

    private var allDone: Bool { batchProgresses.allSatisfy { if case .done = $0.status { return true }; return false } }
    private var isSingleBusy: Bool { downloadingFileID != nil }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea()
                GridBackgroundView(spacing: 25, lineColor: Color.cyan.opacity(0.05)).ignoresSafeArea()

                VStack(spacing: 0) {
                    if fetcher.isLoading {
                        Spacer()
                        VStack(spacing: 20) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.cyan)
                                .scaleEffect(1.5)
                            Text("Đang đồng bộ máy chủ...")
                                .font(.headline)
                                .foregroundColor(.cyan)
                        }
                        Spacer()
                    } else if fetcher.onlineFiles.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "cloud.slash")
                                .font(.system(size: 45))
                                .foregroundColor(.gray)
                            Text("Không có bản Patch nào trên Server")
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    } else {
                        // ── Download All button ──────────────────────────────
                        downloadAllButton
                            .padding(.horizontal, 16)
                            .padding(.top, 12)

                        // ── Batch progress list ──────────────────────────────
                        if isBatchRunning || !batchProgresses.isEmpty {
                            batchProgressSection
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                        }

                        // ── Individual file cards ───────────────────────────
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(fetcher.onlineFiles) { file in
                                    onlineItemCardView(file)
                                }
                            }
                            .padding(16)
                            .padding(.top, showSuccessToast ? 60 : 10)
                        }
                    }
                }

                if showSuccessToast {
                    successToastView
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        ))
                        .zIndex(1)
                }
            }
            .navigationTitle("Download File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(Color.gray.opacity(0.7))
                    }
                }
            }
            .task {
                await fetcher.fetchServerFiles()
                // REQ 1: Auto-start handled by AutoPatchEngine (banner in top-right).
                // OnlineFilesSheetView is now only opened manually; batch auto-run removed here.
            }
            .alert("Tải Về Hoàn Tất", isPresented: $showBatchSummary) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Đã tải \(batchDoneCount) patch thành công" +
                     (batchErrorCount > 0 ? ", \(batchErrorCount) thất bại." : "."))
            }
        }
    }

    // MARK: Download All Button

    private var downloadAllButton: some View {
        Button {
            guard !isBatchRunning, !isSingleBusy else { return }
            startBatchDownload()
        } label: {
            HStack(spacing: 10) {
                if isBatchRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else {
                    Image(systemName: "arrow.down.to.line.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(isBatchRunning ? "Đang Tải Xuống…" : "Download All Patches")
                    .font(.system(size: 15, weight: .bold))
            }
            .foregroundColor(isBatchRunning ? .white.opacity(0.7) : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: isBatchRunning
                        ? [Color.gray.opacity(0.4), Color.gray.opacity(0.3)]
                        : [Color.cyan.opacity(0.75), Color(red: 0.08, green: 0.45, blue: 0.75)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
            )
        }
        .disabled(isBatchRunning || isSingleBusy || fetcher.onlineFiles.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: isBatchRunning)
    }

    // MARK: Batch Progress Section

    @ViewBuilder
    private var batchProgressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tiến Trình Tải Xuống")
                .font(.caption.weight(.semibold))
                .foregroundColor(.gray)

            ForEach(batchProgresses) { progress in
                batchProgressRow(progress)
            }
        }
        .padding(12)
        .background(Color(red: 0.10, green: 0.12, blue: 0.18).opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        )
    }

    @ViewBuilder
    private func batchProgressRow(_ p: PatchDownloadProgress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(p.title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                batchStatusLabel(p.status)
            }
            ProgressView(value: p.fraction)
                .progressViewStyle(.linear)
                .tint(batchTint(p.status))
                .animation(.easeInOut(duration: 0.15), value: p.fraction)
        }
    }

    private func batchStatusLabel(_ status: PatchDownloadProgress.DownloadStatus) -> some View {
        Group {
            switch status {
            case .pending:
                Text("Chờ").font(.caption2).foregroundColor(.gray)
            case .downloading:
                Text("Đang tải").font(.caption2).foregroundColor(.cyan)
            case .importing:
                Text("Đang nhập").font(.caption2).foregroundColor(.yellow)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            case .failed(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }

    private func batchTint(_ status: PatchDownloadProgress.DownloadStatus) -> Color {
        switch status {
        case .pending: return .gray
        case .downloading: return .cyan
        case .importing: return .yellow
        case .done: return .green
        case .failed: return .red
        }
    }

    // MARK: Batch Download Logic

    private func startBatchDownload() {
        let files = fetcher.onlineFiles
        guard !files.isEmpty else { return }
        isBatchRunning = true
        batchDoneCount = 0
        batchErrorCount = 0
        batchProgresses = files.map {
            PatchDownloadProgress(id: $0.id, title: $0.title, fraction: 0, status: .pending)
        }

        Task(priority: .userInitiated) {
            // PatchProjectStore is deliberately serialized: importPackage()
            // rejects a second import while the first transaction is busy.
            // Running these imports concurrently silently drops every import
            // after the first one. Downloads remain complete, but installation
            // is performed one package at a time and each import is awaited.
            for file in files {
                if Task.isCancelled { break }
                await downloadSingleForBatch(file)
            }
            await MainActor.run {
                isBatchRunning = false
                showBatchSummary = true
            }
        }
    }

    private func downloadSingleForBatch(_ file: OnlineFileItem) async {
        guard let url = URL(string: file.url) else {
            updateBatch(id: file.id, fraction: 0, status: .failed("URL không hợp lệ"))
            await MainActor.run { batchErrorCount += 1 }
            return
        }

        // Validate HTTPS
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            updateBatch(id: file.id, fraction: 0, status: .failed("URL phải HTTPS"))
            await MainActor.run { batchErrorCount += 1 }
            return
        }

        updateBatch(id: file.id, fraction: 0.05, status: .downloading)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true

        do {
            let (temporaryURL, response) = try await URLSession(configuration: config).download(from: url)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) else {
                throw OnlinePatchDownloadError.badResponse
            }
            try verifyDownloadedPatch(at: temporaryURL, manifest: file)

            updateBatch(id: file.id, fraction: 0.6, status: .importing)

            let fileName = file.filename.isEmpty ? url.lastPathComponent : file.filename
            let finalName = fileName.hasSuffix(".3105") ? fileName : "\(fileName).3105"
            let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
            let imported = await store.importPackageAndWait(
                data: data,
                password: file.password
            )
            guard imported else {
                updateBatch(id: file.id, fraction: 0, status: .failed("Import thất bại"))
                await MainActor.run { batchErrorCount += 1 }
                return
            }

            let packageID = try? PatchPackageCodec.inspect(data).packageID
            fetcher.recordSuccessfulImport(file, packageID: packageID)

            log("batch-download: imported \(finalName)")
            updateBatch(id: file.id, fraction: 1.0, status: .done)
            await MainActor.run { batchDoneCount += 1 }

        } catch {
            let msg = error.localizedDescription.isEmpty ? "Lỗi tải xuống" : error.localizedDescription
            log("batch-download: failed \(file.filename) – \(error.localizedDescription)")
            updateBatch(id: file.id, fraction: 0, status: .failed(msg))
            await MainActor.run { batchErrorCount += 1 }
        }
    }

    @MainActor
    private func updateBatch(id: String, fraction: Double, status: PatchDownloadProgress.DownloadStatus) {
        guard let idx = batchProgresses.firstIndex(where: { $0.id == id }) else { return }
        batchProgresses[idx].fraction = fraction
        batchProgresses[idx].status = status
    }

    // MARK: Individual card (unchanged appearance, single download)

    private var successToastView: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26))
                .foregroundColor(.green)
                .background(Circle().fill(Color.white).frame(width: 14, height: 14))
            Text("Đã Tải File Xuống Và Patch Thành Công")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(red: 0.08, green: 0.15, blue: 0.1).opacity(0.95))
        .cornerRadius(30)
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.clear, lineWidth: 0))
        .shadow(color: Color.green.opacity(0.4), radius: 15, x: 0, y: 5)
        .padding(.top, 16)
    }

    @ViewBuilder
    private func onlineItemCardView(_ file: OnlineFileItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 24))
                .foregroundColor(.cyan)
                .frame(width: 44, height: 44)
                .background(Color.cyan.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(file.title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                Text(file.filename)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                downloadAndImport(file: file)
            } label: {
                if downloadingFileID == file.id {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.cyan)
                        .padding(8)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.cyan)
                        .background(Circle().fill(Color.black))
                }
            }
            .disabled(downloadingFileID != nil || isBatchRunning)
        }
        .padding(16)
        .background(Color(red: 0.10, green: 0.14, blue: 0.20).opacity(0.8))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.clear, lineWidth: 0)
        )
    }

    // Existing single-file download (unchanged logic, migrated to async/await)
    private func downloadAndImport(file: OnlineFileItem) {
        guard let url = URL(string: file.url) else {
            log("single-download: invalid URL for \(file.filename)")
            return
        }
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            log("single-download: rejected non-HTTPS URL for \(file.filename)")
            return
        }
        downloadingFileID = file.id

        Task(priority: .userInitiated) {
            defer { downloadingFileID = nil }
            do {
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 45
                config.timeoutIntervalForResource = 120
                config.waitsForConnectivity = true
                let (temporaryURL, response) = try await URLSession(configuration: config).download(from: url)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw OnlinePatchDownloadError.badResponse
                }
                try verifyDownloadedPatch(at: temporaryURL, manifest: file)

                let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                let imported = await store.importPackageAndWait(
                    data: data,
                    password: file.password
                )
                guard imported else {
                    throw PatchPackageError.invalidPasswordOrCorruptedPackage
                }
                let packageID = try? PatchPackageCodec.inspect(data).packageID
                fetcher.recordSuccessfulImport(file, packageID: packageID)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { showSuccessToast = true }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(.easeOut(duration: 0.5)) { showSuccessToast = false }
            } catch {
                log("single-download: failed \(file.filename) – \(error.localizedDescription)")
            }
        }
    }

    private func verifyDownloadedPatch(at url: URL, manifest file: OnlineFileItem) throws {
        if let expectedSize = file.size, expectedSize > 0 {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.fileSize == expectedSize else {
                throw OnlinePatchDownloadError.sizeMismatch
            }
        }

        guard let rawChecksum = file.sha256 else { return }
        let expected = rawChecksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard expected.count == 64,
              expected.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else {
            throw OnlinePatchDownloadError.checksumMismatch
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            if Task.isCancelled { throw CancellationError() }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw OnlinePatchDownloadError.checksumMismatch
        }
    }
}

// MARK: - Main Patch Projects View

struct PatchProjectsView: View {
    @StateObject private var store = PatchProjectStore()
    @ObservedObject private var appearance = AppearanceSettings.shared
    @StateObject private var patchState = PatchToggleStore()
    @ObservedObject private var fetcher = OnlineFileFetcher.shared

    /// Nhóm các patch theo game/ứng dụng (hiển thị cả patch trên server và đã tải)
    private var groups: [PatchAppGroup] {
        PatchAppGrouping.makeGroups(from: store.items, onlineFiles: fetcher.onlineFiles)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlobalBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(minimum: 0), spacing: 8),
                                GridItem(.flexible(minimum: 0), spacing: 8)
                            ],
                            alignment: .center,
                            spacing: 8
                        ) {
                            ForEach(groups) { group in
                                NavigationLink {
                                    PatchAppDetailView(
                                        group: group,
                                        appearance: appearance,
                                        patchState: patchState,
                                        store: store
                                    )
                                } label: {
                                    PatchAppCard(group: group, appearance: appearance)
                                }
                                .buttonStyle(.plain).techButtonChrome()
                            }
                        }

                        if groups.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 96)
                }

            }
            .navigationTitle("Chức năng")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await fetcher.fetchServerFiles(force: true)
                store.reload()
            }
            .task {
                await fetcher.fetchServerFiles()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(appearance.resolvedAppButtonColor)
            Text("Chưa có chức năng")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Các nhóm FFM, FFTH, CAPCUT, PUBG và LIÊN QUÂN đã được chuẩn bị sẵn.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - Patch toggle state

@MainActor
final class PatchToggleStore: ObservableObject {
    @Published private(set) var enabledIDs: Set<UUID>
    @Published private(set) var busyIDs: Set<UUID> = []
    @Published private(set) var remainingSeconds: [UUID: Int] = [:]
    @Published var errorMessage: String?

    private let storageKey = "PatchProjects.enabledPatchIDs.v2"
    private let deadlinesStorageKey = "PatchProjects.autoDisableDeadlines.v1"
    private var autoDisableTasks: [UUID: Task<Void, Never>] = [:]
    private var autoDisableDeadlines: [UUID: Date] = [:]
    private var autoDisableSettingsObserver: NSObjectProtocol?

    init() {
        let values = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        enabledIDs = Set(values.compactMap(UUID.init(uuidString:)))
        autoDisableDeadlines = Self.loadDeadlines()

        autoDisableSettingsObserver = NotificationCenter.default.addObserver(
            forName: .fluxCoreAutoDisableSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A settings change starts a fresh configured interval for
                // already-enabled patches instead of retaining the old deadline.
                self.autoDisableDeadlines.removeAll()
                self.persistDeadlines()
                self.refreshAutoDisableSchedules()
            }
        }
    }

    func isEnabled(_ item: PatchLibraryItem) -> Bool {
        enabledIDs.contains(item.id)
    }

    func isBusy(_ item: PatchLibraryItem) -> Bool {
        busyIDs.contains(item.id)
    }

    /// The transaction journal is the source of truth for the actual filesystem
    /// state. UserDefaults is only a persistence hint for the UI.
    func reconcile(_ items: [PatchLibraryItem]) {
        currentItems = items
        var actualEnabled = enabledIDs
        let ids = Set(items.map(\.id))
        actualEnabled.subtract(ids)

        for item in items {
            if DevicePatchService.latestAppliedReceipt(projectID: item.id) != nil {
                actualEnabled.insert(item.id)
            } else {
                actualEnabled.remove(item.id)
            }
        }

        if actualEnabled != enabledIDs {
            enabledIDs = actualEnabled
            persist()
        }
        refreshAutoDisableSchedules()
    }

    /// Changes the real patch state, not merely the visual toggle. ON creates a
    /// transaction and writes the replacement files. OFF restores the verified
    /// originals from that transaction. The UI state is committed only after the
    /// filesystem operation succeeds.
    func setEnabled(_ enabled: Bool, for item: PatchLibraryItem) {
        guard !busyIDs.contains(item.id) else { return }

        // Manual OFF always cancels a pending automatic restore for this patch.
        if !enabled {
            autoDisableTasks[item.id]?.cancel()
            autoDisableTasks[item.id] = nil
            autoDisableDeadlines[item.id] = nil
            remainingSeconds[item.id] = nil
            persistDeadlines()
        }
        guard let baseProject = item.project else {
            errorMessage = "Patch này đang bị khóa. Hãy mở khóa package trước khi bật."
            return
        }

        let projectID = item.id
        let itemSnapshot = item
        let baseProjectSnapshot = baseProject

        busyIDs.insert(projectID)
        errorMessage = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if enabled {
                    let project: PatchProject
                    if itemSnapshot.summary.schemaVersion >= 2 {
                        project = try PatchProjectLibrary.synchronizeWorkspace(item: itemSnapshot)
                    } else {
                        project = baseProjectSnapshot
                    }

                    // Smart replacement: terminate only active patches that
                    // conflict with the incoming target set, then apply the new
                    // transaction. Unrelated active patches remain untouched.
                    let deactivatedIDs = try DevicePatchService.deactivateConflictingPatches(
                        project: project,
                        excludingProjectID: projectID
                    )
                    if !deactivatedIDs.isEmpty {
                        await self?.markAutoDeactivated(deactivatedIDs)
                    }

                    // Replace an older transaction belonging to this same project
                    // with a fresh backup of the current originals.
                    if let previousReceipt = DevicePatchService.latestReceipt(projectID: projectID) {
                        try DevicePatchService.restore(receipt: previousReceipt)
                    }

                    _ = try DevicePatchService.apply(project: project)
                } else {
                    guard let receipt = DevicePatchService.latestReceipt(projectID: projectID) else {
                        await self?.finishToggle(projectID: projectID, enabled: false)
                        return
                    }
                    try DevicePatchService.restore(receipt: receipt)
                }

                await self?.finishToggle(projectID: projectID, enabled: enabled)
            } catch let error as PatchPackageError {
                await self?.failToggle(
                    projectID: projectID,
                    message: error.errorDescription ?? "Không thể thay đổi trạng thái patch."
                )
            } catch {
                await self?.failToggle(
                    projectID: projectID,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func markAutoDeactivated(_ projectIDs: Set<UUID>) {
        for id in projectIDs {
            enabledIDs.remove(id)
            autoDisableTasks[id]?.cancel()
            autoDisableTasks[id] = nil
            autoDisableDeadlines[id] = nil
            remainingSeconds[id] = nil
        }
        persistDeadlines()
        persist()

        if !projectIDs.isEmpty {
            FluxStatusNotificationCenter.shared.post(
                title: "Patch replaced",
                detail: "Conflicting patch automatically deactivated",
                isOn: false
            )
        }
    }

    func toggle(_ item: PatchLibraryItem) {
        setEnabled(!isEnabled(item), for: item)
    }

    func clearError() {
        errorMessage = nil
    }

    private func finishToggle(projectID: UUID, enabled: Bool) {
        if enabled {
            enabledIDs.insert(projectID)
            autoDisableDeadlines[projectID] = nil
        } else {
            enabledIDs.remove(projectID)
            autoDisableTasks[projectID]?.cancel()
            autoDisableTasks[projectID] = nil
            autoDisableDeadlines[projectID] = nil
            remainingSeconds[projectID] = nil
            persistDeadlines()
        }
        persist()
        busyIDs.remove(projectID)

        if enabled {
            scheduleAutoDisableIfNeeded(for: projectID)
        }

        FluxStatusNotificationCenter.shared.post(
            title: "Patch \(enabled ? "enabled" : "disabled")",
            detail: "Patch state updated successfully",
            isOn: enabled
        )
    }

    /// Schedules exactly one restore operation per enabled patch and maintains a
    /// live UI countdown. The persisted deadline survives relaunches.
    private func scheduleAutoDisableIfNeeded(for projectID: UUID) {
        autoDisableTasks[projectID]?.cancel()
        autoDisableTasks[projectID] = nil
        remainingSeconds[projectID] = nil

        let settings = AppearanceSettings.shared
        guard settings.autoDisablePatches else {
            autoDisableDeadlines[projectID] = nil
            persistDeadlines()
            return
        }

        let now = Date()
        let deadline = autoDisableDeadlines[projectID] ?? now.addingTimeInterval(
            min(max(settings.autoDisablePatchSeconds, 1), 20)
        )
        autoDisableDeadlines[projectID] = deadline
        persistDeadlines()

        autoDisableTasks[projectID] = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let remaining = Int(ceil(deadline.timeIntervalSinceNow))
                if remaining <= 0 {
                    self.remainingSeconds[projectID] = 0
                    self.autoDisableTasks[projectID] = nil
                    self.autoDisableDeadlines[projectID] = nil
                    self.persistDeadlines()

                    guard settings.autoDisablePatches,
                          let item = self.itemForAutoDisable(projectID),
                          self.isEnabled(item),
                          !self.isBusy(item) else {
                        self.remainingSeconds[projectID] = nil
                        return
                    }

                    self.setEnabled(false, for: item)
                    return
                }

                if self.remainingSeconds[projectID] != remaining {
                    self.remainingSeconds[projectID] = remaining
                }
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func itemForAutoDisable(_ projectID: UUID) -> PatchLibraryItem? {
        // The patch list is not retained by the store, so the current UI supplies
        // the concrete item through the helper below when scheduling is refreshed.
        currentItems.first { $0.id == projectID }
    }

    private var currentItems: [PatchLibraryItem] = []

    func updateAutoDisableItems(_ items: [PatchLibraryItem]) {
        currentItems = items
        refreshAutoDisableSchedules()
    }

    private func refreshAutoDisableSchedules() {
        autoDisableTasks.values.forEach { $0.cancel() }
        autoDisableTasks.removeAll()

        guard AppearanceSettings.shared.autoDisablePatches else {
            remainingSeconds.removeAll()
            autoDisableDeadlines.removeAll()
            persistDeadlines()
            return
        }

        for projectID in enabledIDs {
            scheduleAutoDisableIfNeeded(for: projectID)
        }
    }

    private func failToggle(projectID: UUID, message: String) {
        busyIDs.remove(projectID)
        errorMessage = message
    }

    deinit {
        autoDisableTasks.values.forEach { $0.cancel() }
        if let observer = autoDisableSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func persistDeadlines() {
        let encoded = autoDisableDeadlines.reduce(into: [String: Double]()) { result, pair in
            result[pair.key.uuidString] = pair.value.timeIntervalSince1970
        }
        UserDefaults.standard.set(encoded, forKey: deadlinesStorageKey)
    }

    private static func loadDeadlines() -> [UUID: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: "PatchProjects.autoDisableDeadlines.v1") as? [String: Double] else {
            return [:]
        }
        return raw.reduce(into: [UUID: Date]()) { result, pair in
            if let id = UUID(uuidString: pair.key) {
                result[id] = Date(timeIntervalSince1970: pair.value)
            }
        }
    }

    private func persist() {
        UserDefaults.standard.set(
            enabledIDs.map(\.uuidString).sorted(),
            forKey: storageKey
        )
    }
}

// MARK: - Patch function info

private enum PatchInfoTopic: Identifiable {
    case function(PatchType)
    case patch(PatchType)

    var id: String {
        switch self {
        case .function(let type): return "function-\(type.rawValue)"
        case .patch(let type): return "patch-\(type.rawValue)"
        }
    }

    var type: PatchType {
        switch self {
        case .function(let type), .patch(let type): return type
        }
    }

    var titleKey: String {
        switch self {
        case .function: return "patch.info.function.title"
        case .patch: return "patch.info.patch.title"
        }
    }

    var descriptionKey: String {
        switch self {
        case .function(let type):
            switch type {
            case .aim: return "patch.info.aim.description"
            case .visual: return "patch.info.holo.description"
            case .mod: return "patch.info.mod.description"
            case .utility: return "patch.info.utility.description"
            case .other: return "patch.info.other.description"
            }
        case .patch(let type):
            switch type {
            case .aim: return "patch.info.aim.toggle"
            case .visual: return "patch.info.holo.toggle"
            case .mod: return "patch.info.mod.toggle"
            case .utility: return "patch.info.utility.toggle"
            case .other: return "patch.info.other.toggle"
            }
        }
    }
}

private struct PatchFunctionInfoSheet: View {
    let topic: PatchInfoTopic
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(appearance.resolvedAppButtonColor)
                    Text(language.text(topic.titleKey, topic.type.rawValue.uppercased()))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(language.text("common.close")) { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(appearance.resolvedAppButtonColor)
                }

                Text(language.text(topic.descriptionKey))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Image(systemName: "hand.tap.fill")
                        .foregroundStyle(appearance.resolvedAppButtonColor)
                    Text(language.text("patch.info.badge_note"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(12)
                .background(
                    Color.white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                }

                Spacer()
            }
            .padding(20)
        }
    }
}

// MARK: - App grouping

enum PatchEntry: Identifiable, Hashable {
    case installed(item: PatchLibraryItem, file: OnlineFileItem?)
    case cloud(file: OnlineFileItem)

    var id: String {
        switch self {
        case .installed(let item, _):
            return item.id.uuidString
        case .cloud(let file):
            return "cloud_\(file.id)"
        }
    }

    var title: String {
        switch self {
        case .installed(let item, let file):
            if let file, !file.title.isEmpty {
                return file.title
            }
            return PatchAppGrouping.patchDisplayTitle(for: item)
        case .cloud(let file):
            return file.title
        }
    }

    var isInstalled: Bool {
        switch self {
        case .installed: return true
        case .cloud: return false
        }
    }

    var installedItem: PatchLibraryItem? {
        switch self {
        case .installed(let item, _): return item
        case .cloud: return nil
        }
    }

    var cloudFile: OnlineFileItem? {
        switch self {
        case .installed(_, let file): return file
        case .cloud(let file): return file
        }
    }

    var patchType: PatchType {
        switch self {
        case .installed(let item, let file):
            if let file, let cat = PatchType.serverCategory(file.category) {
                return cat
            }
            return PatchAppGrouping.patchType(for: item)
        case .cloud(let file):
            if let cat = PatchType.serverCategory(file.category) {
                return cat
            }
            return PatchType.classify(file.title)
        }
    }

    var formattedSize: String? {
        guard let size = cloudFile?.size, size > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    static func == (lhs: PatchEntry, rhs: PatchEntry) -> Bool {
        lhs.id == rhs.id && lhs.isInstalled == rhs.isInstalled
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(isInstalled)
    }
}

struct PatchAppGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifiers: [String]
    let entries: [PatchEntry]
    let kind: PatchAppKind

    var items: [PatchLibraryItem] {
        entries.compactMap { $0.installedItem }
    }

    var packageNames: [String] {
        items.map { $0.packageURL.lastPathComponent }
    }

    /// Free Fire categories come from the website manifest. Imported packages
    /// without server metadata retain name-based classification as a fallback.
    func entries(for type: PatchType) -> [PatchEntry] {
        guard kind == .ffm || kind == .ffth else { return [] }
        return entries.filter {
            $0.patchType == type
        }
    }

    func items(for type: PatchType) -> [PatchLibraryItem] {
        entries(for: type).compactMap { $0.installedItem }
    }

    var primaryBundleID: String? { bundleIdentifiers.first }

    static func == (lhs: PatchAppGroup, rhs: PatchAppGroup) -> Bool {
        lhs.id == rhs.id && lhs.entries == rhs.entries
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum PatchAppKind: String, CaseIterable {
    case ffm
    case ffth
    case capcut
    case pubg
    case lienQuan
    case locket
    case other

    var displayName: String {
        switch self {
        case .ffm: return "FREE FIRE MAX"
        case .ffth: return "FREE FIRE THƯỜNG"
        case .capcut: return "CAPCUT"
        case .pubg: return "PUBG"
        case .lienQuan: return "LIÊN QUÂN"
        case .locket: return "LOCKET"
        case .other: return "Khác"
        }
    }

    var defaultBundleID: String? {
        switch self {
        case .ffm: return "com.dts.freefiremax"
        case .ffth: return "com.dts.freefireth"
        case .capcut: return "com.lemon.lvoverseas"
        case .pubg: return "com.tencent.ig"
        case .lienQuan: return "com.garena.game.kgvn"
        case .locket: return "com.locket.Locket"
        case .other: return nil
        }
    }
}

@MainActor
enum PatchAppGrouping {
    private static let predefined: [(kind: PatchAppKind, name: String)] = [
        (.ffth, "FREE FIRE THƯỜNG"),
        (.ffm, "FREE FIRE MAX"),
        (.capcut, "CAPCUT"),
        (.pubg, "PUBG"),
        (.lienQuan, "LIÊN QUÂN"),
        (.locket, "LOCKET")
    ]

    @MainActor private static var cachedItems: [PatchLibraryItem] = []
    @MainActor private static var cachedOnlineFiles: [OnlineFileItem] = []
    @MainActor private static var cachedGroups: [PatchAppGroup] = []

    @MainActor
    static func makeGroups(
        from items: [PatchLibraryItem],
        onlineFiles: [OnlineFileItem]? = nil
    ) -> [PatchAppGroup] {
        let activeFiles = onlineFiles ?? OnlineFileFetcher.shared.onlineFiles
        if !cachedGroups.isEmpty && cachedItems == items && cachedOnlineFiles == activeFiles {
            return cachedGroups
        }
        var buckets: [String: [PatchEntry]] = [:]
        var kinds: [String: PatchAppKind] = [:]
        var names: [String: String] = [:]
        var bundles: [String: [String]] = [:]

        // Always create the requested top-level buttons, even before a patch exists.
        for (kind, name) in predefined {
            let key = key(for: kind)
            buckets[key] = []
            kinds[key] = kind
            names[key] = name
            if let bundleID = kind.defaultBundleID {
                bundles[key] = [bundleID]
            }
        }

        // Build index of local items for correlation
        var localByPackageID: [String: PatchLibraryItem] = [:]
        var localByIdentity: [String: PatchLibraryItem] = [:]
        for item in items {
            let pkgID = item.summary.packageID.uuidString.lowercased()
            localByPackageID[pkgID] = item

            let fileIdent = normalizedCompact(item.packageURL.deletingPathExtension().lastPathComponent)
            if !fileIdent.isEmpty { localByIdentity[fileIdent] = item }
            if let projName = item.project?.name {
                let projIdent = normalizedCompact(projName)
                if !projIdent.isEmpty { localByIdentity[projIdent] = item }
            }
        }

        var matchedLocalIDs = Set<UUID>()
        var resolvedEntries: [(kinds: [PatchAppKind], entry: PatchEntry)] = []

        // Process online files first so metadata and categorization from server are prioritized
        for file in activeFiles {
            var matchedItem: PatchLibraryItem?
            if let rawPkg = file.packageID, let uuid = UUID(uuidString: rawPkg) {
                matchedItem = localByPackageID[uuid.uuidString.lowercased()]
            }
            if matchedItem == nil, let storedPkg = ServerPatchMetadataStore.packageID(for: file) {
                matchedItem = localByPackageID[storedPkg.lowercased()]
            }
            if matchedItem == nil {
                let fileIdent = normalizedCompact(URL(fileURLWithPath: file.filename).deletingPathExtension().lastPathComponent)
                matchedItem = localByIdentity[fileIdent]
            }
            if matchedItem == nil {
                let titleIdent = normalizedCompact(file.title)
                matchedItem = localByIdentity[titleIdent]
            }

            let entry: PatchEntry
            if let matched = matchedItem {
                matchedLocalIDs.insert(matched.id)
                entry = .installed(item: matched, file: file)
            } else {
                entry = .cloud(file: file)
            }

            let fileKinds = kindsForFile(file)
            resolvedEntries.append((fileKinds, entry))
        }

        // Process remaining local items (manual imports or offline)
        for item in items where !matchedLocalIDs.contains(item.id) {
            let raw = classificationName(for: item)
            let itemKinds = targetKinds(for: item, fallbackName: raw).filter { $0 != .other }
            let entry = PatchEntry.installed(item: item, file: nil)
            resolvedEntries.append((itemKinds.isEmpty ? [.other] : itemKinds, entry))
        }

        // Add entries into buckets
        for (entryKinds, entry) in resolvedEntries {
            for kind in entryKinds {
                let groupKey = key(for: kind)
                if !(buckets[groupKey] ?? []).contains(where: { $0.id == entry.id }) {
                    buckets[groupKey, default: []].append(entry)
                }
                kinds[groupKey] = kind

                if names[groupKey] == nil {
                    names[groupKey] = kind.displayName
                }

                if let bundleID = kind.defaultBundleID {
                    if !(bundles[groupKey] ?? []).contains(bundleID) {
                        bundles[groupKey, default: []].append(bundleID)
                    }
                }

                if let localItem = entry.installedItem {
                    for bundleID in localItem.project?.allBundleIdentifiers ?? [] where !bundleID.isEmpty {
                        if !(bundles[groupKey] ?? []).contains(bundleID) {
                            bundles[groupKey, default: []].append(bundleID)
                        }
                    }
                }
            }
        }

        let result: [PatchAppGroup] = buckets.compactMap { key, groupedEntries -> PatchAppGroup? in
            guard let kind = kinds[key], let name = names[key] else { return nil }
            let sortedEntries = groupedEntries.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }

            return PatchAppGroup(
                id: key,
                name: name,
                bundleIdentifiers: bundles[key] ?? [],
                entries: sortedEntries,
                kind: kind
            )
        }
        .sorted { (lhs: PatchAppGroup, rhs: PatchAppGroup) -> Bool in
            let order: [PatchAppKind] = [.ffth, .ffm, .capcut, .pubg, .lienQuan, .locket, .other]
            let li = order.firstIndex(of: lhs.kind) ?? order.count
            let ri = order.firstIndex(of: rhs.kind) ?? order.count
            if li != ri { return li < ri }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        cachedItems = items
        cachedOnlineFiles = activeFiles
        cachedGroups = result
        return result
    }

    private static func kindsForFile(_ file: OnlineFileItem) -> [PatchAppKind] {
        if let game = file.game?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch game {
            case "ff": return [.ffth]
            case "ffm": return [.ffm]
            case "all": return [.ffth, .ffm]
            case "capcut": return [.capcut]
            case "pubg": return [.pubg]
            case "lienquan": return [.lienQuan]
            case "locket": return [.locket]
            default: break
            }
        }
        let fallbackKind = classifyKind(file.title + " " + file.filename)
        if fallbackKind != .other {
            return [fallbackKind]
        }
        return [.ffth, .ffm]
    }

    nonisolated static func classificationName(for item: PatchLibraryItem) -> String {
        let project = item.project?.name ?? ""
        let filename = item.packageURL.deletingPathExtension().lastPathComponent
        return project.isEmpty ? filename : "\(project) \(filename)"
    }

    nonisolated static func patchDisplayTitle(for item: PatchLibraryItem) -> String {
        ServerPatchMetadataStore.displayTitle(for: item)
    }

    nonisolated static func patchType(for item: PatchLibraryItem) -> PatchType {
        if let metadata = ServerPatchMetadataStore.record(for: item),
           let type = PatchType.serverCategory(metadata.category) {
            return type
        }
        return PatchType.classify(classificationName(for: item))
    }

    private static func targetKinds(
        for item: PatchLibraryItem,
        fallbackName: String
    ) -> [PatchAppKind] {
        if let game = ServerPatchMetadataStore.record(for: item)?.game.lowercased() {
            switch game {
            case "ff": return [.ffth]
            case "ffm": return [.ffm]
            case "all": return [.ffth, .ffm]
            case "capcut": return [.capcut]
            case "pubg": return [.pubg]
            case "lienquan": return [.lienQuan]
            case "locket": return [.locket]
            default: break
            }
        }
        let fallbackKind = classifyKind(fallbackName)
        if fallbackKind != .other {
            return [fallbackKind]
        }
        return [.ffth, .ffm]
    }

    private static func classifyKind(_ raw: String) -> PatchAppKind {
        let compact = normalizedCompact(raw)

        // FF and FFM are intentionally checked separately and never merged.
        if containsToken(compact, token: "freefiremax") || containsToken(compact, token: "ffm") {
            return .ffm
        }
        if containsToken(compact, token: "ffth") || containsToken(compact, token: "freefire") {
            return .ffth
        }
        if compact.contains("capcut") { return .capcut }
        if compact.contains("pubg") { return .pubg }
        if compact.contains("lienquan") { return .lienQuan }
        if compact.contains("locket") { return .locket }
        return .other
    }

    private static func key(for kind: PatchAppKind) -> String {
        "system-\(kind.rawValue)"
    }

    private static func normalizedCompact(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "")
            .lowercased()
    }

    private static func containsToken(_ compact: String, token: String) -> Bool {
        compact.contains(token)
    }

    private static func displayName(for raw: String, item: PatchLibraryItem) -> String {
        switch classifyKind(raw) {
        case .ffm: return "FREE FIRE MAX"
        case .ffth: return "FREE FIRE THƯỜNG"
        case .capcut: return "CAPCUT"
        case .pubg: return "PUBG"
        case .lienQuan: return "LIÊN QUÂN"
        case .locket: return "LOCKET"
        case .other:
            if let name = item.project?.name,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
            return item.packageURL.deletingPathExtension().lastPathComponent
        }
    }
}

// MARK: - App card

private struct PatchAppCard: View {
    private static let locketCoverPageURL = "https://ibb.co/8Lq2Dmd8"
    private static let locketCoverImageURL = "https://i.ibb.co/pBcZv1RX/IMG-8870.jpg"

    let group: PatchAppGroup
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject private var autoPatch = AutoPatchEngine.shared

    private var patchCount: Int { group.entries.count }

    @ViewBuilder
    private var appCardIcon: some View {
        if group.kind == .locket {
            if let localURL = DynamicAssetRouter.assetURL(for: "system-locket") {
                AsyncImage(url: localURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else if let url = URL(string: Self.locketCoverImageURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Image(systemName: "heart.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
        } else {
            InstalledAppIconView(bundleID: group.primaryBundleID)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            appCardIcon
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                }
                .shadow(color: appearance.resolvedAppButtonColor.opacity(0.16), radius: 12, y: 5)
                .appLaunchIconGlow()

            Text(group.name)
                .font(.system(size: 12.5, weight: appearance.fontWeight.swiftUI, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(group.primaryBundleID ?? "Chưa có package")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            if group.kind == .ffm || group.kind == .ffth {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(PatchType.allCases.filter { !group.entries(for: $0).isEmpty }) { type in
                            typeBadge(type.shortLabel, count: group.entries(for: type).count)
                        }
                    }
                }
            }

            Group {
                if autoPatch.isRunning && patchCount == 0 {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(appearance.resolvedAppButtonColor)
                        .scaleEffect(0.72)
                        .frame(height: 12)
                        .accessibilityLabel("Đang cập nhật danh sách")
                } else if patchCount == 0 {
                    Text("Sẵn sàng tích hợp")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(appearance.resolvedAppButtonColor.opacity(0.82))
                } else {
                    Text("\(patchCount) patch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(appearance.resolvedAppButtonColor.opacity(0.82))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 154)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(cardBackground)
        .overlay(cardBorder)
        .clipShape(RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(appearance.cardCornerRadius), style: .continuous))
        .shadow(color: appearance.resolvedAppButtonColor.opacity(0.08), radius: 12, y: 5)
        .opacity(appearance.globalOpacity)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(appearance.cardCornerRadius), style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        appearance.resolvedAppButtonColor.opacity(0.08),
                        Color.black.opacity(appearance.cardFillOpacity)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(appearance.cardCornerRadius), style: .continuous)
            .stroke(Color.clear, lineWidth: 0)
    }

    private func typeBadge(_ title: String, count: Int) -> some View {
        Text(count > 0 ? "\(title) \(count)" : title)
            .font(.system(size: 6.5, weight: .bold, design: .monospaced))
            .foregroundStyle(count > 0 ? appearance.resolvedAppButtonColor : .white.opacity(0.35))
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                appearance.resolvedAppButtonColor.opacity(count > 0 ? 0.11 : 0.035),
                in: Capsule()
            )
        .accessibilityIdentifier(group.id == "system-locket" ? "patch.app.locket" : group.id)
    }
}

private struct InstalledAppIconView: View {
    let bundleID: String?
    @ObservedObject private var appearance = AppearanceSettings.shared

    private var suppliedIconURL: URL? {
        guard let bundleID else { return nil }

        switch bundleID {
        case "com.dts.freefireth":
            return URL(string: "https://i.ibb.co/27CQSgHV/IMG-8638.png")
        case "com.dts.freefiremax":
            return URL(string: "https://i.ibb.co/jZMDVKPs/IMG-8637.png")
        case "com.lemon.lvoverseas":
            return URL(string: "https://i.ibb.co/Gv6DThXB/IMG-8639.jpg")
        case "com.tencent.ig":
            return URL(string: "https://i.ibb.co/5Xvm4Nc6/IMG-8640.jpg")
        case "com.garena.game.kgvn":
            return URL(string: "https://i.ibb.co/3mr8wR8m/IMG-8641.jpg")
        default:
            return nil
        }
    }

    @ViewBuilder
    private var fallbackIcon: some View {
        if let bundleID, let image = iconForBundleID(bundleID) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        appearance.resolvedAppButtonColor.opacity(0.28),
                        Color.black.opacity(0.50)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "app.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
            }
        }
    }

    private var cachedIconURL: URL? {
        guard let bundleID else { return nil }
        switch bundleID {
        case "com.dts.freefireth": return AssetPreloadService.cachedURL(key: "icon.ffth")
        case "com.dts.freefiremax": return AssetPreloadService.cachedURL(key: "icon.ffm")
        case "com.lemon.lvoverseas": return AssetPreloadService.cachedURL(key: "icon.capcut")
        case "com.tencent.ig": return AssetPreloadService.cachedURL(key: "icon.pubg")
        case "com.garena.game.kgvn": return AssetPreloadService.cachedURL(key: "icon.lienquan")
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let cachedIconURL {
                Image(uiImage: UIImage(contentsOfFile: cachedIconURL.path) ?? UIImage())
                    .resizable()
                    .scaledToFill()
            } else if let suppliedIconURL {
                AsyncImage(url: suppliedIconURL, transaction: Transaction(animation: .easeOut(duration: 0.20))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallbackIcon
                    case .empty:
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(appearance.resolvedAppButtonColor.opacity(0.12))
                            ProgressView()
                                .tint(appearance.resolvedAppButtonColor)
                                .scaleEffect(0.75)
                        }
                    @unknown default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .clipped()
        .accessibilityLabel(bundleID ?? "Application icon")
    }
}

// MARK: - App detail

private struct PatchAppDetailView: View {
    let group: PatchAppGroup
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var patchState: PatchToggleStore
    @ObservedObject var store: PatchProjectStore
    @ObservedObject private var fetcher = OnlineFileFetcher.shared
    @Namespace private var selectorNamespace
    @ObservedObject private var functionSettings = PatchFunctionSettings.shared
    @Environment(\.appLanguage) private var language
    @State private var selectedType: PatchType = .aim
    @State private var openResult: String?
    @State private var infoTopic: PatchInfoTopic?

    private var activeGroup: PatchAppGroup {
        PatchAppGrouping.makeGroups(from: store.items, onlineFiles: fetcher.onlineFiles)
            .first(where: { $0.id == group.id }) ?? group
    }

    /// Free Fire and Free Fire MAX expose the categories selected on the web.
    /// Other applications intentionally expose their patches directly so they
    /// do not inherit the Free Fire category UI.
    private var usesFunctionChannels: Bool {
        activeGroup.kind == .ffm || activeGroup.kind == .ffth
    }

    private var selectedEntries: [PatchEntry] {
        // Free Fire groups use the exact Patch Cloud category.
        // All other known apps (CAPCUT, PUBG, LIÊN QUÂN) expose patches directly.
        guard usesFunctionChannels else { return activeGroup.entries }
        return activeGroup.entries(for: selectedType)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            GlobalBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader
                    if usesFunctionChannels {
                        typeSelector
                    }
                    requirementsSection
                }
                .padding(16)
                .padding(.bottom, 92)
            }

            openAppBar
                .padding(.trailing, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .zIndex(100)
        }
        .navigationTitle(activeGroup.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $infoTopic) { topic in
            PatchFunctionInfoSheet(topic: topic)
                .presentationDetents([.height(330), .medium])
                .presentationDragIndicator(.visible)
        }
        .alert("Không thể mở ứng dụng", isPresented: Binding(
            get: { openResult != nil },
            set: { if !$0 { openResult = nil } }
        )) {
            Button("OK", role: .cancel) { openResult = nil }
        } message: {
            Text(openResult ?? "Ứng dụng chưa được cài đặt hoặc không thể mở.")
        }
        .task {
            patchState.reconcile(activeGroup.items)
            if activeGroup.entries(for: selectedType).isEmpty,
               let firstAvailable = PatchType.allCases.first(where: { !activeGroup.entries(for: $0).isEmpty }) {
                selectedType = firstAvailable
            }
        }
        .alert("Không thể thay đổi patch", isPresented: Binding(
            get: { patchState.errorMessage != nil },
            set: { if !$0 { patchState.clearError() } }
        )) {
            Button("OK", role: .cancel) { patchState.clearError() }
        } message: {
            Text(patchState.errorMessage ?? "Không thể thay đổi trạng thái patch.")
        }
    }

    private var detailHeader: some View {
        // REQ 4: .other kind gets a dedicated "Khác" tech icon instead of an app icon
        let isOther = activeGroup.kind == .other
        let otherAccent = Color(red: 1.0, green: 0.72, blue: 0.10)  // amber gold for "Khác"
        let cr = appearance.appButtonStyle.cornerRadius(appearance.cardCornerRadius)

        return HStack(spacing: 14) {
            if isOther {
                // Tech icon for the "Khác" / unknown patch bucket
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [otherAccent.opacity(0.30), otherAccent.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(otherAccent)
                        .shadow(color: otherAccent.opacity(0.60), radius: 10)
                }
                .frame(width: 74, height: 74)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.clear, lineWidth: 0)
                }
                .shadow(color: otherAccent.opacity(0.30), radius: 12, y: 4)
            } else {
                InstalledAppIconView(bundleID: activeGroup.primaryBundleID)
                    .frame(width: 74, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.clear, lineWidth: 0)
                    }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(activeGroup.name)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if isOther {
                    // REQ 4: Explain the "Khác" bucket
                    Text("Patch không xác định loại")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(otherAccent.opacity(0.72))
                        .lineLimit(1)
                } else if let bundle = activeGroup.primaryBundleID {
                    Text(bundle)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Text(activeGroup.entries.isEmpty ? "Chưa có patch" : "\(activeGroup.entries.count) patch")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOther ? otherAccent : appearance.resolvedAppButtonColor)
            }
            Spacer()
        }
        .padding(14)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: cr, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cr, style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
    }

    // MARK: - FLUXCORE: Patch Cloud category selector

    /// Responsive grid of Patch Cloud category buttons.
    /// Each button carries a custom tech icon, a glow ring, and an animated
    /// selection state consistent with the Free Fire / FLUXCORE visual language.
    private var typeSelector: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(PatchType.allCases) { type in
                typeSelectorButton(for: type)
            }
        }
    }

    /// Returns the SF Symbol name that best represents each channel.
    /// Each website category receives a distinct icon.
    private func typeIconName(_ type: PatchType) -> String {
        switch type {
        case .aim:  return "scope"                        // crosshair/scope — precision aim
        case .visual: return "dot.radiowaves.up.forward"  // display/ESP signal
        case .mod:  return "wrench.adjustable.fill"       // mod tool
        case .utility: return "slider.horizontal.3"
        case .other: return "square.grid.2x2.fill"
        }
    }

    /// Secondary decorative icon layered behind the primary icon.
    private func typeIconSecondary(_ type: PatchType) -> String {
        switch type {
        case .aim:  return "triangle.fill"
        case .visual: return "hexagon.fill"
        case .mod:  return "gear"
        case .utility: return "circle.grid.cross.fill"
        case .other: return "diamond.fill"
        }
    }

    /// One high-tech button cell for a Patch Cloud category.
    @ViewBuilder
    private func typeSelectorButton(for type: PatchType) -> some View {
        let isSelected = selectedType == type
        let accent = functionSettings.color(for: type)
        let visualOpacity = functionSettings.opacity(for: type) * appearance.functionSelectorOpacity
        let cornerRadius = CGFloat(min(max(appearance.functionSelectorCornerRadius, 8), 36))

        ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(
                    appearance.animationsEnabled
                        ? .spring(response: 0.26 * appearance.animationDurationMultiplier, dampingFraction: 0.78)
                        : nil
                ) {
                    selectedType = type
                }
            } label: {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(accent.opacity(0.16))
                            .matchedGeometryEffect(id: "selected-channel", in: selectorNamespace)
                    }

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            isSelected
                                ? LinearGradient(
                                    colors: [
                                        accent.opacity(0.28),
                                        accent.opacity(0.10),
                                        Color.black.opacity(0.30)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                  )
                                : LinearGradient(
                                    colors: [Color.white.opacity(0.05), Color.white.opacity(0.02)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                  )
                        )

                    Image(systemName: typeIconSecondary(type))
                        .font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(accent.opacity(isSelected ? 0.10 : 0.04))
                        .rotationEffect(.degrees(isSelected ? 30 : 0))
                        .scaleEffect(isSelected ? 1.12 : 1.0)
                        .animation(.easeInOut(duration: 0.5), value: isSelected)
                        .offset(x: 18, y: -10)

                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(accent.opacity(isSelected ? 0.22 : 0.08))
                                .frame(width: 48, height: 48)
                                .blur(radius: 4)

                            Image(systemName: typeIconName(type))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(accent)
                                .shadow(color: accent.opacity(0.75), radius: isSelected ? 8 : 3)
                        }

                        Text(type.rawValue.uppercased())
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(isSelected ? .white : Color.white.opacity(0.42))

                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)

                    if isSelected {
                        VStack {
                            Capsule()
                                .fill(accent)
                                .frame(width: 28, height: 2.5)
                                .shadow(color: accent.opacity(0.90), radius: 5)
                            Spacer()
                        }
                        .padding(.top, 0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .techBorder(
                enabled: appearance.technologyBorderEnabled,
                color: appearance.resolvedBorderColor,
                cornerRadius: cornerRadius,
                width: appearance.buttonBorderWidth
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.clear, lineWidth: 0)
            }
            .shadow(color: isSelected ? accent.opacity(0.35) : .clear, radius: 14, y: 4)
            .scaleEffect(isSelected ? 1.025 : 1.0)
            .opacity(visualOpacity)
            .animation(.spring(response: 0.28, dampingFraction: 0.80), value: isSelected)

            .padding(7)
            .accessibilityLabel("Thông tin \(type.rawValue)")
        }
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(usesFunctionChannels ? "Yêu cầu chức năng" : "Chức năng")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }

            if selectedEntries.isEmpty {
                Text(
                    usesFunctionChannels
                        ? "Chưa có patch \(selectedType.rawValue) cho \(activeGroup.name)."
                        : "Chưa có patch cho \(activeGroup.name)."
                )
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.50))
                    .padding(.vertical, 20)
            } else {
                ForEach(selectedEntries) { entry in
                    switch entry {
                    case .installed(let item, _):
                        patchRequirementRow(item)
                    case .cloud(let file):
                        cloudPatchRow(file, entry: entry)
                    }
                }
            }
        }
    }

    private func patchRequirementRow(_ item: PatchLibraryItem) -> some View {
        let busy = patchState.isBusy(item)
        let enabled = patchState.isEnabled(item)
        let itemType = PatchAppGrouping.patchType(for: item)
        let visualOpacity = functionSettings.opacity(for: itemType)

        return HStack(spacing: 12) {
            Image(systemName: item.isLocked ? "lock.doc.fill" : "shippingbox.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(appearance.resolvedAppButtonColor)
                .frame(width: 38, height: 38)
                .background(
                    appearance.resolvedAppButtonColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(11), style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(PatchAppGrouping.patchDisplayTitle(for: item))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                // Patch cards intentionally expose only the patch name and its
                // live enabled/disabled state; secondary metadata is hidden.
                Text(
                    busy ? "Đang xử lý…" :
                    enabled ? "Đang bật" : "Đang tắt"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    busy ? appearance.resolvedAppButtonColor :
                    enabled ? appearance.resolvedAppButtonColor : .white.opacity(0.42)
                )
            }

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                if appearance.autoDisablePatches && enabled,
                   let remaining = patchState.remainingSeconds[item.id] {
                    Text("\(remaining)s")
                        .font(.system(size: 12, weight: appearance.patchCountdownFontWeight.swiftUI, design: .monospaced))
                        .foregroundStyle((Color(hex: appearance.patchCountdownColorHex) ?? appearance.resolvedAppButtonColor)
                            .opacity(appearance.patchCountdownOpacity))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            (Color(hex: appearance.patchCountdownColorHex) ?? appearance.resolvedAppButtonColor)
                                .opacity(0.10 * appearance.patchCountdownOpacity),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(Color.clear, lineWidth: 0)
                        }
                        .accessibilityLabel("Tự động tắt sau \(remaining) giây")
                }


                ZStack {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { enabled },
                        set: { patchState.setEnabled($0, for: item) }
                    )
                )
                .labelsHidden()
                .tint(appearance.resolvedAppButtonColor)
                .disabled(item.isLocked || busy)

                if busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(appearance.resolvedAppButtonColor)
                        .scaleEffect(0.72)
                }
                }
                .frame(width: 48, height: 32)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(
                cornerRadius: appearance.appButtonStyle.cornerRadius(16),
                style: .continuous
            )
            .fill(
                appearance.appButtonStyle == .futuristic
                    ? LinearGradient(
                        colors: [
                            appearance.resolvedAppButtonColor.opacity(0.16),
                            Color.black.opacity(max(0.12, appearance.cardFillOpacity * 0.72))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [
                            Color.black.opacity(max(0.10, appearance.cardFillOpacity * 0.70)),
                            Color.black.opacity(max(0.10, appearance.cardFillOpacity * 0.70))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(16), style: .continuous)
                .stroke(Color.clear, lineWidth: 0)
        }
        .shadow(
            color: appearance.appButtonStyle == .futuristic
                ? appearance.resolvedAppButtonColor.opacity(0.18 * visualOpacity)
                : .clear,
            radius: appearance.appButtonStyle == .futuristic ? 10 : 0,
            y: appearance.appButtonStyle == .futuristic ? 3 : 0
        )
        .opacity(0.35 + (0.65 * visualOpacity))
    }

    private func cloudPatchRow(_ file: OnlineFileItem, entry: PatchEntry) -> some View {
        let isDownloading = fetcher.downloadingIDs.contains(file.id)
        let itemType = entry.patchType
        let visualOpacity = functionSettings.opacity(for: itemType)
        let formattedSize = entry.formattedSize

        return HStack(spacing: 12) {
            Image(systemName: "icloud.and.arrow.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(appearance.resolvedAppButtonColor)
                .frame(width: 38, height: 38)
                .background(
                    appearance.resolvedAppButtonColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(11), style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(file.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(isDownloading ? "Đang tải xuống…" : "Chưa tải về")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isDownloading ? appearance.resolvedAppButtonColor : .white.opacity(0.42))

                    if let formattedSize {
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.25))
                        Text(formattedSize)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                guard !isDownloading else { return }
                Task {
                    await downloadPatch(file: file)
                }
            } label: {
                HStack(spacing: 6) {
                    if isDownloading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Text(isDownloading ? "Đang tải…" : "Tải về")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isDownloading
                        ? Color.white.opacity(0.12)
                        : appearance.resolvedAppButtonColor,
                    in: Capsule()
                )
                .shadow(
                    color: isDownloading ? .clear : appearance.resolvedAppButtonColor.opacity(0.35),
                    radius: 6,
                    y: 2
                )
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDownloading else { return }
            Task {
                await downloadPatch(file: file)
            }
        }
        .background {
            RoundedRectangle(
                cornerRadius: appearance.appButtonStyle.cornerRadius(16),
                style: .continuous
            )
            .fill(
                appearance.appButtonStyle == .futuristic
                    ? LinearGradient(
                        colors: [
                            appearance.resolvedAppButtonColor.opacity(0.08),
                            Color.black.opacity(max(0.12, appearance.cardFillOpacity * 0.72))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        colors: [
                            Color.black.opacity(max(0.10, appearance.cardFillOpacity * 0.70)),
                            Color.black.opacity(max(0.10, appearance.cardFillOpacity * 0.70))
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(16), style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        }
        .shadow(
            color: appearance.appButtonStyle == .futuristic
                ? appearance.resolvedAppButtonColor.opacity(0.10 * visualOpacity)
                : .clear,
            radius: appearance.appButtonStyle == .futuristic ? 10 : 0,
            y: appearance.appButtonStyle == .futuristic ? 3 : 0
        )
        .opacity(0.35 + (0.65 * visualOpacity))
    }

    private func downloadPatch(file: OnlineFileItem) async {
        let ok = await fetcher.downloadSinglePatch(file: file, store: store)
        if ok {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            FluxStatusNotificationCenter.shared.post(
                title: "Đã tải patch",
                detail: file.title,
                isOn: true
            )
        } else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)
            FluxStatusNotificationCenter.shared.post(
                title: "Tải patch thất bại",
                detail: file.title,
                isOn: false
            )
        }
    }

    private var openAppBar: some View {
        Button {
            guard let bundleID = activeGroup.primaryBundleID,
                  !bundleID.isEmpty else {
                openResult = "Chức năng này chưa có package identifier của ứng dụng đích."
                return
            }

            guard openApplicationForBundleID(bundleID) else {
                openResult = "Ứng dụng chưa được cài đặt hoặc LaunchServices không thể mở package này."
                FluxStatusNotificationCenter.shared.post(
                    title: "App launch failed",
                    detail: activeGroup.name,
                    isOn: false
                )
                return
            }

            FluxStatusNotificationCenter.shared.post(
                title: "App launched",
                detail: activeGroup.name,
                isOn: true
            )
        } label: {
            ZStack {
                // The action label is independently centered. The trailing
                // progress indicator never changes the label's center point.
                HStack(spacing: 9) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .black))
                    Text("MỞ APP")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(1.0)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    Spacer()
                    if !fetcher.downloadingIDs.isEmpty {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(appearance.resolvedAppButtonColor)
                            .frame(width: 18, height: 18)
                            .accessibilityLabel("Đang tải Patch")
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .opacity(0.65)
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(18), style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(18), style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        appearance.resolvedAppButtonColor.opacity(0.035),
                                        Color.black.opacity(0.045)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
            )
            .overlay {
                if appearance.appButtonBorderEnabled {
                    RoundedRectangle(
                        cornerRadius: appearance.appButtonStyle.cornerRadius(18),
                        style: .continuous
                    )
                    .stroke(
                        appearance.resolvedAppButtonBorderColor.opacity(
                            appearance.appButtonBorderOpacity
                        ),
                        lineWidth: appearance.appButtonBorderWidth
                    )
                    .shadow(
                        color: appearance.appButtonGlowEnabled
                            ? (Color(hex: appearance.appButtonGlowColorHex) ?? appearance.resolvedAppButtonBorderColor)
                                .opacity(0.78 * appearance.appButtonGlowIntensity)
                            : .clear,
                        radius: appearance.appButtonGlowEnabled
                            ? CGFloat(appearance.appButtonGlowRadius)
                            : 0
                    )
                }
            }
            .shadow(
                color: appearance.appButtonGlowEnabled
                    ? (Color(hex: appearance.appButtonGlowColorHex) ?? appearance.resolvedAppButtonColor)
                        .opacity(0.58 * appearance.appButtonGlowIntensity)
                    : .clear,
                radius: appearance.appButtonGlowEnabled
                    ? CGFloat(appearance.appButtonGlowRadius)
                    : 0,
                y: 5
            )
            .shadow(color: .black.opacity(0.50), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: appearance.appButtonStyle.cornerRadius(18), style: .continuous))
        .accessibilityLabel("Mở ứng dụng")
        .animation(.easeInOut(duration: 0.18), value: !fetcher.downloadingIDs.isEmpty)
    }

    private func count(for type: PatchType) -> Int {
        group.items(for: type).count
    }
}

// MARK: - Grid background
// Uses the shared GridBackgroundView declared in ContentView.swift.

// MARK: - Unlock view (unchanged)

private struct PatchUnlockView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("patch.password"), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in store.clearUnlockError() }
                    if let errorKey = store.unlockErrorKey {
                        Text(language.text(errorKey))
                            .font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text(language.text("patch.password_once_message"))
                }
            }
            .navigationTitle(language.text("patch.unlock"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.unlock"), action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}

// MARK: - Patch Detail View (unchanged)

private struct PatchProjectDetailView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    @State private var showApplyConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?

    private var item: PatchLibraryItem? { store.items.first(where: { $0.id == projectID }) }
    private var receipt: PatchTransactionReceipt? { DevicePatchService.latestReceipt(projectID: projectID) }

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea()
            GridBackgroundView(spacing: 25, lineColor: Color.white.opacity(0.04)).ignoresSafeArea()

            List {
                if let item, let project = item.project {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 20)).foregroundColor(.cyan)
                                .frame(width: 32, height: 32)
                                .background(Color.cyan.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(.body.weight(.semibold)).foregroundColor(.white)
                                Text(item.summary.isPasswordProtected
                                     ? language.text("patch.password_locked")
                                     : language.text("patch.no_password"))
                                    .font(.caption).foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color(red: 0.12, green: 0.12, blue: 0.18).opacity(0.4))

                    Section {
                        Button { showApplyConfirmation = true } label: {
                            HStack {
                                Label("Áp Dụng Patch", systemImage: "checkmark.shield.fill")
                                    .foregroundStyle(LinearGradient(
                                        colors: [Color(red: 0.3, green: 1.0, blue: 0.55), Color.green],
                                        startPoint: .leading, endPoint: .trailing
                                    ))
                                Spacer()
                                if isWorking {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.green)
                                        .scaleEffect(0.8)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isWorking)

                        Button(role: .destructive) { showRestoreConfirmation = true } label: {
                            Label("Khôi Phục File Gốc", systemImage: "arrow.uturn.backward.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(isWorking || receipt == nil)
                    } header: {
                        Text("Hành Động")
                    }
                    .listRowBackground(Color(red: 0.12, green: 0.12, blue: 0.18).opacity(0.4))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(item.map { PatchAppGrouping.patchDisplayTitle(for: $0) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Xác nhận Kích Hoạt", isPresented: $showApplyConfirmation, titleVisibility: .visible) {
            Button("Kích Hoạt") { apply() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.apply_confirm_message"))
        }
        .confirmationDialog("Xác nhận Khôi Phục", isPresented: $showRestoreConfirmation, titleVisibility: .visible) {
            Button("Khôi Phục", role: .destructive) { restore() }
            Button(language.text("common.cancel"), role: .cancel) {}
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(language.text(alert.message(language: language))),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func apply() {
        guard let item, let baseProject = item.project else { return }
        isWorking = true
        Task(priority: .userInitiated) {
            do {
                let project = item.summary.schemaVersion >= 2
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : baseProject
                _ = try DevicePatchService.apply(project: project)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func restore() {
        guard let receipt else { return }
        isWorking = true
        Task(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(receipt: receipt)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }
}
