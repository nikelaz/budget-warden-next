/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import CloudKit
import Foundation

public struct BWCloudBudget: Sendable {
    public let budget: BWBudget
    public let isSharedWithCurrentUser: Bool
    public let isReadOnly: Bool

    public init(budget: BWBudget, isSharedWithCurrentUser: Bool, isReadOnly: Bool) {
        self.budget = budget
        self.isSharedWithCurrentUser = isSharedWithCurrentUser
        self.isReadOnly = isReadOnly
    }
}

/// Stores each budget in its own CloudKit record zone. A zone is the unit shared by
/// CKShare, which lets Budget Warden discover accepted budgets in the shared database.
public actor BWCloudBudgetRepository {
    public static let defaultContainerIdentifier = "iCloud.com.lazarovco.BudgetWarden"

    private enum Schema {
        static let recordType = "Budget"
        static let title = "title"
        static let contents = "contents"
        static let revision = "revision"
        static let zonePrefix = "Budget-"
        static let shareType = "com.lazarovco.budgetwarden.budget"
    }

    private let container: CKContainer
    private struct RecordLocation: Sendable {
        let scope: CKDatabase.Scope
        let recordID: CKRecord.ID
    }
    private var recordLocations: [UUID: RecordLocation] = [:]
    private var legacyMigrationCompletedInSession: Bool?

    public init(containerIdentifier: String = defaultContainerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func accountIsAvailable() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        }
        catch {
            return false
        }
    }

    public func legacyICloudDriveMigrationIsComplete() async -> Bool {
        if let legacyMigrationCompletedInSession {
            return legacyMigrationCompletedInSession
        }

        let migrationKey = await legacyMigrationDefaultsKey()
        let isComplete = UserDefaults.standard.bool(forKey: migrationKey)
        legacyMigrationCompletedInSession = isComplete
        return isComplete
    }

    /// Returns budgets owned by the current user and budgets accepted from other users.
    public func fetchAllBudgets() async -> Result<[BWCloudBudget], BWError> {
        do {
            // @TODO: can these happen concurrently? with something like Promise.all in js? but the swift equivalent?
            let owned = try await fetchBudgets(in: container.privateCloudDatabase, shared: false)
            let shared = try await fetchBudgets(in: container.sharedCloudDatabase, shared: true)
            return .success(owned + shared)
        }
        catch {
            return .failure(.cloudKit(underlying: error))
        }
    }

    /// Fetches the root record from a share invitation directly. CloudKit may not
    /// include a newly accepted zone in database-wide discovery immediately.
    public func fetchSharedBudget(recordID: CKRecord.ID) async -> Result<BWCloudBudget, BWError> {
        do {
            let database = container.sharedCloudDatabase
            let record = try await database.record(for: recordID)

            guard record.recordType == Schema.recordType,
                  let json = try jsonContents(from: record)
            else {
                return .failure(.decodingJson())
            }

            let placeholderURL = URL(fileURLWithPath: "/\(record.recordID.recordName).budget")

            guard case .success(var budget) = BWCodec.decodeBudget(
                json: json,
                url: placeholderURL
            ) else {
                return .failure(.decodingJson())
            }

            budget.url = nil
            recordLocations[budget.id] = RecordLocation(
                scope: .shared,
                recordID: record.recordID
            )

            return .success(BWCloudBudget(
                budget: budget,
                isSharedWithCurrentUser: true,
                isReadOnly: false
            ))
        }
        catch {
            return .failure(.cloudKit(underlying: error))
        }
    }

    /// Creates or updates the owner's CloudKit copy of a budget.
    @discardableResult
    public func save(_ budget: BWBudget) async -> Result<Void, BWError> {
        do {
            let knownLocation = recordLocations[budget.id]
            let database = knownLocation.map { container.database(with: $0.scope) }
                ?? container.privateCloudDatabase
            let recordID = knownLocation?.recordID ?? CKRecord.ID(
                recordName: budget.id.uuidString,
                zoneID: zoneID(for: budget.id)
            )

            if knownLocation == nil {
                try await ensureZone(recordID.zoneID, in: database)
            }
            for _ in 0..<5 {
                let record: CKRecord
                do {
                    record = try await database.record(for: recordID)
                }
                catch let error as CKError where error.code == .unknownItem {
                    record = CKRecord(recordType: Schema.recordType, recordID: recordID)
                }

                var mergedBudget = budget
                if let serverJSON = try jsonContents(from: record) {
                    let placeholderURL = URL(fileURLWithPath: "/\(recordID.recordName).budget")
                    guard case .success(let serverBudget) = BWCodec.decodeBudget(
                        json: serverJSON,
                        url: placeholderURL
                    ) else {
                        return .failure(.decodingJson())
                    }
                    guard case .success(let merged) = BWCRDT.merge(budget, serverBudget) else {
                        return .failure(.rebaseFailed())
                    }
                    mergedBudget = merged
                }

                guard case .success(let json) = BWCodec.encodeBudget(budget: mergedBudget) else {
                    return .failure(.encodingJson())
                }

                if let serverJSON = try jsonContents(from: record),
                   normalizedJSON(serverJSON) == json {
                    recordLocations[budget.id] = RecordLocation(
                        scope: database.databaseScope,
                        recordID: recordID
                    )
                    return .success(())
                }

                let assetURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(BWFiles.budgetFileExtension)
                try Data(json.utf8).write(to: assetURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: assetURL) }

                record[Schema.title] = mergedBudget.title as CKRecordValue
                record[Schema.contents] = CKAsset(fileURL: assetURL)
                record[Schema.revision] = (mergedBudget.revision ?? 1) as CKRecordValue

                let saveResult = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .ifServerRecordUnchanged,
                    atomically: true
                )
                if let result = saveResult.saveResults[recordID] {
                    switch result {
                        case .success:
                            recordLocations[budget.id] = RecordLocation(
                                scope: database.databaseScope,
                                recordID: recordID
                            )
                            return .success(())
                        case .failure(let error as CKError) where error.code == .serverRecordChanged:
                            continue
                        case .failure(let error):
                            throw error
                    }
                }
            }
            return .failure(.rebaseFailed())
        }
        catch {
            return .failure(.cloudKit(underlying: error))
        }
    }

    /// Ensures the budget exists in CloudKit and returns the root record used to create a CKShare.
    public func shareRootRecord(for budget: BWBudget) async -> Result<CKRecord, BWError> {
        if let location = recordLocations[budget.id] {
            do {
                let database = container.database(with: location.scope)
                return .success(try await database.record(for: location.recordID))
            }
            catch {
                return .failure(.cloudKit(underlying: error))
            }
        }

        let privateRecordID = CKRecord.ID(
            recordName: budget.id.uuidString,
            zoneID: zoneID(for: budget.id)
        )

        do {
            let record = try await container.privateCloudDatabase.record(for: privateRecordID)
            recordLocations[budget.id] = RecordLocation(
                scope: .private,
                recordID: privateRecordID
            )
            return .success(record)
        }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            // This budget has not reached CloudKit yet; save it below before sharing.
        }
        catch {
            return .failure(.cloudKit(underlying: error))
        }

        switch await save(budget) {
            case .failure(let error):
                return .failure(error)
            case .success:
                do {
                    let location = recordLocations[budget.id]
                    let recordID = location?.recordID ?? CKRecord.ID(
                        recordName: budget.id.uuidString,
                        zoneID: zoneID(for: budget.id)
                    )
                    let database = location.map { container.database(with: $0.scope) }
                        ?? container.privateCloudDatabase
                    return .success(try await database.record(for: recordID))
                }
                catch {
                    return .failure(.cloudKit(underlying: error))
                }
        }
    }

    /// Returns an existing share or creates a private, read-write share for this budget.
    public func prepareShare(for budget: BWBudget) async -> Result<CKShare, BWError> {
        let rootRecord: CKRecord

        switch await shareRootRecord(for: budget) {
            case .failure(let error):
                return .failure(error)
            case .success(let record):
                rootRecord = record
        }

        do {
            let database = recordLocations[budget.id]
                .map { container.database(with: $0.scope) }
                ?? container.privateCloudDatabase

            if let shareReference = rootRecord.share {
                guard let share = try await database.record(for: shareReference.recordID) as? CKShare else {
                    return .failure(.cloudKit())
                }
                return .success(try await updateShareMetadataIfNeeded(
                    share,
                    budget: budget,
                    database: database
                ))
            }

            guard database.databaseScope == .private else {
                return .failure(.cloudKit())
            }

            let share = CKShare(rootRecord: rootRecord)
            share[CKShare.SystemFieldKey.title] = budget.title as CKRecordValue
            share[CKShare.SystemFieldKey.shareType] = Schema.shareType as CKRecordValue
            share.publicPermission = .none

            let result = try await database.modifyRecords(
                saving: [rootRecord, share],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )

            guard let savedResult = result.saveResults[share.recordID],
                  case .success(let savedShare) = savedResult,
                  let savedShare = savedShare as? CKShare
            else {
                return .failure(.cloudKit())
            }

            return .success(savedShare)
        }
        catch {
            return .failure(.cloudKit(underlying: error))
        }
    }

    public func delete(_ budgetID: UUID) async -> Result<Void, BWError> {
        let location = recordLocations[budgetID] ?? RecordLocation(
            scope: .private,
            recordID: CKRecord.ID(
                recordName: budgetID.uuidString,
                zoneID: zoneID(for: budgetID)
            )
        )

        do {
            let database = container.database(with: location.scope)
            _ = try await database.deleteRecordZone(withID: location.recordID.zoneID)
            recordLocations.removeValue(forKey: budgetID)
            return .success(())
        }
        catch let error as CKError where error.code == .zoneNotFound {
            recordLocations.removeValue(forKey: budgetID)
            return .success(())
        }
        catch {
            return .failure(.cloudKit(underlying: error))
        }
    }

    public func acceptShare(_ metadata: CKShare.Metadata) async -> Result<Void, BWError> {
        guard metadata.participantStatus == .pending else {
            return metadata.participantStatus == .accepted
                ? .success(())
                : .failure(.cloudKit())
        }

        do {
            _ = try await container.accept(metadata)
            return .success(())
        }
        catch {
            return .failure(.cloudKit(underlying: error))
        }
    }

    /// Imports the former iCloud Drive vault once per iCloud account. Existing
    /// CloudKit records win unless the legacy file has a strictly newer revision.
    public func migrateLegacyICloudBudgets(_ legacyBudgets: [BWBudget]) async -> Result<Void, BWError> {
        let migrationKey = await legacyMigrationDefaultsKey()

        guard !UserDefaults.standard.bool(forKey: migrationKey) else {
            legacyMigrationCompletedInSession = true
            return .success(())
        }

        let cloudBudgets: [BWCloudBudget]

        switch await fetchAllBudgets() {
            case .failure(let error):
                return .failure(error)
            case .success(let budgets):
                cloudBudgets = budgets
        }

        var cloudByID: [UUID: BWCloudBudget] = [:]

        for cloud in cloudBudgets where cloudByID[cloud.budget.id] == nil || !cloud.isSharedWithCurrentUser {
            cloudByID[cloud.budget.id] = cloud
        }

        for legacyBudget in legacyBudgets {
            if let cloudBudget = cloudByID[legacyBudget.id] {
                guard !cloudBudget.isSharedWithCurrentUser,
                      (legacyBudget.revision ?? 1) > (cloudBudget.budget.revision ?? 1)
                else {
                    continue
                }
            }

            switch await save(legacyBudget) {
                case .failure(let error):
                    return .failure(error)
                case .success:
                    continue
            }
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
        legacyMigrationCompletedInSession = true
        return .success(())
    }

    /// Uploads pending offline cache edits and refreshes the local cache from both the
    /// private and shared CloudKit databases. Matching CRDT documents are merged.
    public func synchronize(
        localBudgets: [BWBudget],
        vault: BWVault
    ) async -> Result<[BWCloudBudget], BWError> {
        let cloudBudgets: [BWCloudBudget]

        switch await fetchAllBudgets() {
            case .failure(let error):
                return .failure(error)
            case .success(let budgets):
                cloudBudgets = budgets
        }

        let managedDefaultsKey = await managedBudgetDefaultsKey()
        let previouslyManagedIDs = Set(
            (UserDefaults.standard.stringArray(forKey: managedDefaultsKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
        let currentlyManagedIDs = Set(cloudBudgets.lazy.map { $0.budget.id })

        var cloudByID: [UUID: BWCloudBudget] = [:]
        var localByID: [UUID: BWBudget] = [:]

        for cloud in cloudBudgets {
            // Prefer the current user's owned copy if an imported file happens to use
            // the same UUID as a budget shared by somebody else.
            if cloudByID[cloud.budget.id] == nil || !cloud.isSharedWithCurrentUser {
                cloudByID[cloud.budget.id] = cloud
            }
        }

        for local in localBudgets {
            localByID[local.id] = local
        }

        let revokedManagedIDs = previouslyManagedIDs.subtracting(currentlyManagedIDs)
        let revokedOnlyIDs = Set(revokedManagedIDs.filter { cloudByID[$0] == nil })

        for local in localBudgets where revokedOnlyIDs.contains(local.id) {
            if case .failure(let error) = await BWBudgetService.deleteBudget(local, vault: vault) {
                return .failure(error)
            }
            localByID.removeValue(forKey: local.id)
        }

        for local in localBudgets where !revokedOnlyIDs.contains(local.id) {
            guard let cloud = cloudByID[local.id] else {
                if case .failure(let error) = await save(local) {
                    return .failure(error)
                }
                continue
            }

            let merged: BWBudget
            switch BWCRDT.merge(local, cloud.budget) {
                case .failure(let error):
                    return .failure(error)
                case .success(let result):
                    merged = result
            }

            if case .failure(let error) = await vault.cacheCloudBudget(merged) {
                return .failure(error)
            }

            if !cloud.isReadOnly,
               case .failure(let error) = await save(merged) {
                return .failure(error)
            }
        }

        for cloud in cloudBudgets where localByID[cloud.budget.id] == nil {
            if case .failure(let error) = await vault.cacheCloudBudget(cloud.budget) {
                return .failure(error)
            }
        }


        UserDefaults.standard.set(
            currentlyManagedIDs
                .union(localByID.keys)
                .subtracting(revokedOnlyIDs)
                .map(\.uuidString)
                .sorted(),
            forKey: managedDefaultsKey
        )

        return .success(cloudBudgets)
    }

    private func fetchBudgets(in database: CKDatabase, shared: Bool) async throws -> [BWCloudBudget] {
        let zones = try await database.allRecordZones()
        var budgets: [BWCloudBudget] = []

        for zone in zones where zone.zoneID.zoneName.hasPrefix(Schema.zonePrefix) {
            let recordName = String(zone.zoneID.zoneName.dropFirst(Schema.zonePrefix.count))

            guard UUID(uuidString: recordName) != nil else {
                continue
            }

            let recordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)
            let record: CKRecord

            do {
                record = try await database.record(for: recordID)
            }
            catch let error as CKError where error.code == .unknownItem {
                continue
            }

            guard record.recordType == Schema.recordType,
                  let json = try jsonContents(from: record)
            else {
                continue
            }

            let placeholderURL = URL(fileURLWithPath: "/\(record.recordID.recordName).budget")

            guard case .success(var budget) = BWCodec.decodeBudget(json: json, url: placeholderURL) else {
                continue
            }

            budget.url = nil
            if recordLocations[budget.id] == nil || !shared {
                recordLocations[budget.id] = RecordLocation(
                    scope: database.databaseScope,
                    recordID: record.recordID
                )
            }
            budgets.append(BWCloudBudget(
                budget: budget,
                isSharedWithCurrentUser: shared,
                isReadOnly: false
            ))
        }

        return budgets
    }

    private func ensureZone(_ zoneID: CKRecordZone.ID, in database: CKDatabase) async throws {
        do {
            _ = try await database.recordZone(for: zoneID)
        }
        catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(CKRecordZone(zoneID: zoneID))
        }
    }

    private func updateShareMetadataIfNeeded(
        _ share: CKShare,
        budget: BWBudget,
        database: CKDatabase
    ) async throws -> CKShare {
        var needsSave = false

        if share[CKShare.SystemFieldKey.title] as? String != budget.title {
            share[CKShare.SystemFieldKey.title] = budget.title as CKRecordValue
            needsSave = true
        }

        if share[CKShare.SystemFieldKey.shareType] as? String != Schema.shareType {
            share[CKShare.SystemFieldKey.shareType] = Schema.shareType as CKRecordValue
            needsSave = true
        }

        guard needsSave else {
            return share
        }

        guard let savedShare = try await database.save(share) as? CKShare else {
            throw BWError.cloudKit()
        }

        return savedShare
    }

    private func jsonContents(from record: CKRecord) throws -> String? {
        if let asset = record[Schema.contents] as? CKAsset,
           let fileURL = asset.fileURL {
            return try String(contentsOf: fileURL, encoding: .utf8)
        }

        return record[Schema.contents] as? String
    }

    private func normalizedJSON(_ json: String) -> String? {
        let placeholderURL = URL(fileURLWithPath: "/CloudKit.budget")

        guard case .success(let budget) = BWCodec.decodeBudget(
            json: json,
            url: placeholderURL
        ),
        case .success(let normalizedJSON) = BWCodec.encodeBudget(budget: budget)
        else {
            return nil
        }

        return normalizedJSON
    }

    private func managedBudgetDefaultsKey() async -> String {
        let accountID = (try? await container.userRecordID().recordName) ?? "unknown"
        return "BW_CLOUD_MANAGED_BUDGET_IDS_\(accountID)"
    }

    private func legacyMigrationDefaultsKey() async -> String {
        let accountID = (try? await container.userRecordID().recordName) ?? "unknown"
        return "BW_CLOUDKIT_LEGACY_ICLOUD_DRIVE_MIGRATION_V1_\(accountID)"
    }

    private func zoneID(for budgetID: UUID) -> CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: Schema.zonePrefix + budgetID.uuidString,
            ownerName: CKCurrentUserDefaultName
        )
    }
}
