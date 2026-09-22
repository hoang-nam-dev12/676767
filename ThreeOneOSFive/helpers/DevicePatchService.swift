import Foundation

enum DevicePatchService {
    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(receipt: PatchTransactionReceipt) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    static func latestAppliedReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestAppliedReceipt(projectID: projectID, backupRoot: backupRoot)
    }


    /// Restores only active projects that overlap this project's file targets.
    /// This makes activation deterministic: the incoming patch owns a target
    /// before it is applied, while unrelated active patches remain untouched.
    @discardableResult
    static func deactivateConflictingPatches(
        project: PatchProject,
        excludingProjectID: UUID? = nil
    ) throws -> Set<UUID> {
        let backupRoot = try PatchProjectLibrary.backupRootURL()
        var incomingKeys = Set<String>()

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            incomingKeys.insert(bundleID + "\0" + relativePath)
        }

        let conflictingIDs = PatchTransaction.activeProjectIDs(
            overlapping: incomingKeys,
            backupRoot: backupRoot,
            excludingProjectID: excludingProjectID
        )

        for projectID in conflictingIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let receipt = PatchTransaction.latestAppliedReceipt(
                projectID: projectID,
                backupRoot: backupRoot
            ) else { continue }
            try restore(receipt: receipt)
        }
        return conflictingIDs
    }

    static func validateNoActiveTargetConflict(
        project: PatchProject,
        excludingProjectID: UUID? = nil
    ) throws {
        let backupRoot = try PatchProjectLibrary.backupRootURL()
        let activeTargets = PatchTransaction.activeTargetKeys(
            backupRoot: backupRoot,
            excludingProjectID: excludingProjectID
        )

        for rule in project.rules {
            let bundleID = try PatchPathValidator.canonicalBundleIdentifier(rule.bundleID)
            let relativePath = try PatchPathValidator.canonicalRelativePath(rule.relativePath)
            if activeTargets.contains(bundleID + "\0" + relativePath) {
                throw PatchPackageError.activePatchConflict
            }
        }
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]

        for bundleID in bundleIDs {
            guard let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
                  ContainerStore.isApplicationContainerPath(path) else {
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }
            roots[bundleID] = PatchPathValidator.canonicalFileURL(URL(fileURLWithPath: path, isDirectory: true))
        }
        return try operation(roots)
    }
}
