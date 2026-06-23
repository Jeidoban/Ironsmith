import Foundation

struct IronsmithPersistentStoreLocations {
    let databaseDirectoryURL: URL
    let storeURL: URL
    let backupsDirectoryURL: URL
    let legacyStoreURL: URL

    init(databaseDirectoryURL: URL, legacyStoreURL: URL) {
        self.databaseDirectoryURL = databaseDirectoryURL
        storeURL = databaseDirectoryURL.appendingPathComponent(IronsmithPaths.databaseFileName)
        backupsDirectoryURL = databaseDirectoryURL.appendingPathComponent("backups", isDirectory: true)
        self.legacyStoreURL = legacyStoreURL
    }

    static func live(fileManager: FileManager = .default) throws -> Self {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return Self(
            databaseDirectoryURL: IronsmithPaths.databaseDirectory,
            legacyStoreURL: applicationSupportURL.appendingPathComponent("default.store")
        )
    }
}
