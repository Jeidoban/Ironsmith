import CoreData
import Foundation

struct IronsmithPersistentStorePreparer {
    private static let retainedBackupCount = 3
    private static let storeComponentSuffixes = ["", "-wal", "-shm", "-journal"]
    private static let importMoveOrder = ["-wal", "-shm", "-journal", ""]
    private static let ironsmithEntityNames = Set(["Tool", "ModelConfig", "ProviderConfig"])

    let locations: IronsmithPersistentStoreLocations
    let fileManager: FileManager

    init(
        locations: IronsmithPersistentStoreLocations,
        fileManager: FileManager = .default
    ) {
        self.locations = locations
        self.fileManager = fileManager
    }

    func prepare(startupDate: Date = .now) throws {
        try fileManager.createDirectory(
            at: locations.databaseDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: locations.backupsDirectoryURL,
            withIntermediateDirectories: true
        )

        try quarantineRejectedLegacyImportIfNeeded(at: startupDate)

        if !regularFileExists(at: locations.storeURL) {
            try importLegacyStoreIfPresent()
        }

        if regularFileExists(at: locations.storeURL) {
            try createStartupBackup(at: startupDate)
            try pruneOldBackups()
        }
    }

    private func importLegacyStoreIfPresent() throws {
        guard regularFileExists(at: locations.legacyStoreURL),
              storeIdentity(at: locations.legacyStoreURL)?.isIronsmith == true
        else {
            return
        }

        for suffix in Self.storeComponentSuffixes.dropFirst() {
            let destinationURL = storeComponentURL(baseURL: locations.storeURL, suffix: suffix)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
        }

        let stagingDirectoryURL = locations.databaseDirectoryURL
            .appendingPathComponent(".legacy-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: false)

        var movedDestinationURLs: [URL] = []
        do {
            for suffix in Self.storeComponentSuffixes {
                let sourceURL = storeComponentURL(baseURL: locations.legacyStoreURL, suffix: suffix)
                guard regularFileExists(at: sourceURL) else { continue }

                let stagedURL = stagingDirectoryURL
                    .appendingPathComponent(locations.storeURL.lastPathComponent + suffix)
                try fileManager.copyItem(at: sourceURL, to: stagedURL)
            }

            for suffix in Self.importMoveOrder {
                let stagedURL = stagingDirectoryURL
                    .appendingPathComponent(locations.storeURL.lastPathComponent + suffix)
                guard regularFileExists(at: stagedURL) else { continue }

                let destinationURL = storeComponentURL(baseURL: locations.storeURL, suffix: suffix)
                try fileManager.moveItem(at: stagedURL, to: destinationURL)
                movedDestinationURLs.append(destinationURL)
            }

            try fileManager.removeItem(at: stagingDirectoryURL)
        } catch {
            for destinationURL in movedDestinationURLs {
                try? fileManager.removeItem(at: destinationURL)
            }
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        }
    }

    private func quarantineRejectedLegacyImportIfNeeded(at startupDate: Date) throws {
        guard regularFileExists(at: locations.storeURL),
              regularFileExists(at: locations.legacyStoreURL),
              let currentIdentity = storeIdentity(at: locations.storeURL),
              let legacyIdentity = storeIdentity(at: locations.legacyStoreURL),
              !currentIdentity.isIronsmith,
              !legacyIdentity.isIronsmith,
              currentIdentity.storeUUID == legacyIdentity.storeUUID
        else {
            return
        }

        let quarantineDirectoryURL = uniqueRejectedLegacyImportDirectoryURL(for: startupDate)
        let stagingDirectoryURL = locations.backupsDirectoryURL
            .appendingPathComponent(".rejected-legacy-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: false)

        var movedComponents: [(source: URL, staged: URL)] = []
        do {
            for suffix in Self.importMoveOrder {
                let sourceURL = storeComponentURL(baseURL: locations.storeURL, suffix: suffix)
                guard regularFileExists(at: sourceURL) else { continue }

                let stagedURL = stagingDirectoryURL
                    .appendingPathComponent(locations.storeURL.lastPathComponent + suffix)
                try fileManager.moveItem(at: sourceURL, to: stagedURL)
                movedComponents.append((sourceURL, stagedURL))
            }
            try fileManager.moveItem(at: stagingDirectoryURL, to: quarantineDirectoryURL)
        } catch {
            for component in movedComponents.reversed()
            where fileManager.fileExists(atPath: component.staged.path) {
                try? fileManager.moveItem(at: component.staged, to: component.source)
            }
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        }
    }

    private func storeIdentity(at url: URL) -> PersistentStoreIdentity? {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: url
        ),
            let versionHashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any],
            let storeUUID = metadata[NSStoreUUIDKey] as? String
        else {
            return nil
        }

        return PersistentStoreIdentity(
            entityNames: Set(versionHashes.keys),
            storeUUID: storeUUID
        )
    }

    private func createStartupBackup(at startupDate: Date) throws {
        let backupDirectoryURL = uniqueBackupDirectoryURL(for: startupDate)
        let stagingDirectoryURL = locations.backupsDirectoryURL
            .appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: false)

        do {
            for suffix in Self.storeComponentSuffixes {
                let sourceURL = storeComponentURL(baseURL: locations.storeURL, suffix: suffix)
                guard regularFileExists(at: sourceURL) else { continue }

                let destinationURL = stagingDirectoryURL
                    .appendingPathComponent(locations.storeURL.lastPathComponent + suffix)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            try fileManager.moveItem(at: stagingDirectoryURL, to: backupDirectoryURL)
        } catch {
            try? fileManager.removeItem(at: stagingDirectoryURL)
            throw error
        }
    }

    private func uniqueBackupDirectoryURL(for date: Date) -> URL {
        let baseName = backupDateFormatter.string(from: date)
        var candidateURL = locations.backupsDirectoryURL
            .appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = locations.backupsDirectoryURL
                .appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidateURL
    }

    private func uniqueRejectedLegacyImportDirectoryURL(for date: Date) -> URL {
        let baseName = "rejected-legacy-import-\(backupDateFormatter.string(from: date))"
        var candidateURL = locations.backupsDirectoryURL
            .appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = locations.backupsDirectoryURL
                .appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidateURL
    }

    private func pruneOldBackups() throws {
        let backupDirectoryURLs = try fileManager.contentsOfDirectory(
            at: locations.backupsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { isCompletedBackupDirectory($0) }
        .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for backupDirectoryURL in backupDirectoryURLs.dropFirst(Self.retainedBackupCount) {
            try fileManager.removeItem(at: backupDirectoryURL)
        }
    }

    private func isCompletedBackupDirectory(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }

        let name = url.lastPathComponent
        guard name.count >= 19 else { return false }

        let timestampEndIndex = name.index(name.startIndex, offsetBy: 19)
        let timestamp = String(name[..<timestampEndIndex])
        guard backupDateFormatter.date(from: timestamp) != nil else { return false }

        let suffix = name[timestampEndIndex...]
        return suffix.isEmpty
            || (suffix.first == "-" && suffix.dropFirst().allSatisfy(\.isNumber))
    }

    private var backupDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }

    private func storeComponentURL(baseURL: URL, suffix: String) -> URL {
        URL(fileURLWithPath: baseURL.path + suffix)
    }

    private func regularFileExists(at url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private struct PersistentStoreIdentity {
        let entityNames: Set<String>
        let storeUUID: String

        var isIronsmith: Bool {
            IronsmithPersistentStorePreparer.ironsmithEntityNames.isSubset(of: entityNames)
        }
    }
}
