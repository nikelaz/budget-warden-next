/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import Foundation

public struct BWGoogleDriveBudget: Sendable {
    public let budget: BWBudget
    public let fileID: String
    public let ownerEmail: String?
    public let isSharedWithCurrentUser: Bool

    public init(
        budget: BWBudget,
        fileID: String,
        ownerEmail: String?,
        isSharedWithCurrentUser: Bool
    ) {
        self.budget = budget
        self.fileID = fileID
        self.ownerEmail = ownerEmail
        self.isSharedWithCurrentUser = isSharedWithCurrentUser
    }
}

/// Mirrors the Android Drive vault contract while keeping authentication and UI
/// presentation in the platform applications. Every downloaded document is first
/// merged into the local cache with BWCRDT, so an upload never blindly replaces a
/// concurrent remote edit.
public actor BWGoogleDriveRepository {
    public static let driveScope = "https://www.googleapis.com/auth/drive"
    public static let folderName = "Budget Warden Vault"
    public static let budgetMIMEType = "application/vnd.budgetwarden.budget+json"

    private struct RemoteFile: Decodable, Sendable {
        struct Owner: Decodable, Sendable {
            let emailAddress: String?
        }

        let id: String
        let name: String
        let version: String?
        let owners: [Owner]?
        let sharedWithMeTime: String?

        var numericVersion: Int64 {
            Int64(version ?? "") ?? 0
        }
    }

    private struct FileList: Decodable {
        let files: [RemoteFile]
        let nextPageToken: String?
    }

    private struct Folder: Decodable {
        let id: String
    }

    private struct Metadata: Codable, Sendable {
        var fileID: String
        var version: Int64
        var ownerEmail: String?
        var sharedWithCurrentUser: Bool
    }

    private struct HTTPFailure: LocalizedError {
        let operation: String
        let statusCode: Int
        let response: String

        var errorDescription: String? {
            let detail = response.isEmpty ? "" : " \(response)"
            return "Google Drive \(operation) failed (\(statusCode)).\(detail)"
        }
    }

    private let vault: BWVault
    private let session: URLSession
    private let defaults: UserDefaults
    private let metadataKey: String
    private var metadata: [UUID: Metadata]

    public init(
        vault: BWVault,
        metadataKey: String,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        self.vault = vault
        self.metadataKey = metadataKey
        self.defaults = defaults
        self.session = session

        if let data = defaults.data(forKey: metadataKey),
           let saved = try? JSONDecoder().decode([UUID: Metadata].self, from: data) {
            metadata = saved
        }
        else {
            metadata = [:]
        }
    }

    public func synchronize(accessToken: String) async -> Result<[BWGoogleDriveBudget], BWError> {
        do {
            _ = try await findOrCreateVault(accessToken: accessToken)
            let remoteFiles = try await listBudgetFiles(accessToken: accessToken)
            let localResult = await BWBudgetService.loadBudgets(vault: vault)
            let localBudgets = try localResult.get().budgets
            var localByID = Dictionary(uniqueKeysWithValues: localBudgets.map { ($0.id, $0) })
            var discovered: [BWGoogleDriveBudget] = []
            let previouslyKnownMetadata = metadata

            for remote in remoteFiles {
                let data = try await download(fileID: remote.id, accessToken: accessToken)
                let remoteBudget = try decodeBudget(data)

                let cached: BWBudget
                if let local = localByID[remoteBudget.id] {
                    cached = try BWCRDT.merge(local, remoteBudget).get()
                }
                else {
                    cached = remoteBudget
                }

                let stored = try await vault.cacheCloudBudget(cached).get()
                localByID[stored.id] = stored
                metadata[stored.id] = Metadata(
                    fileID: remote.id,
                    version: remote.numericVersion,
                    ownerEmail: remote.owners?.first?.emailAddress,
                    sharedWithCurrentUser: remote.sharedWithMeTime != nil
                )

                let cachedJSON = try BWCodec.encodeBudget(budget: cached).get()
                let remoteJSON = try BWCodec.encodeBudget(budget: remoteBudget).get()
                if cachedJSON != remoteJSON {
                    let uploaded = try await upload(
                        budget: stored,
                        fileID: remote.id,
                        folderID: nil,
                        accessToken: accessToken
                    )
                    metadata[stored.id]?.version = uploaded.numericVersion
                }

                discovered.append(BWGoogleDriveBudget(
                    budget: stored,
                    fileID: remote.id,
                    ownerEmail: remote.owners?.first?.emailAddress,
                    isSharedWithCurrentUser: remote.sharedWithMeTime != nil
                ))
            }

            // Files created in the Drive cache while offline have no remote mapping yet.
            let folderID = try await findOrCreateVault(accessToken: accessToken)
            for local in localByID.values where metadata[local.id] == nil {
                let uploaded = try await upload(
                    budget: local,
                    fileID: nil,
                    folderID: folderID,
                    accessToken: accessToken
                )
                metadata[local.id] = Metadata(
                    fileID: uploaded.id,
                    version: uploaded.numericVersion,
                    ownerEmail: uploaded.owners?.first?.emailAddress,
                    sharedWithCurrentUser: false
                )
                discovered.append(BWGoogleDriveBudget(
                    budget: local,
                    fileID: uploaded.id,
                    ownerEmail: uploaded.owners?.first?.emailAddress,
                    isSharedWithCurrentUser: false
                ))
            }

            // A formerly synchronized remote file that disappeared was deleted or the
            // current user lost access. Remove only its cache copy, never unrelated files.
            for (budgetID, saved) in previouslyKnownMetadata
                where !remoteFiles.contains(where: { $0.id == saved.fileID }) {
                if let local = localByID[budgetID] {
                    _ = await BWBudgetService.deleteBudget(local, vault: vault)
                }
                metadata.removeValue(forKey: budgetID)
            }

            persistMetadata()
            return .success(discovered.sorted {
                $0.budget.title.localizedStandardCompare($1.budget.title) == .orderedAscending
            })
        }
        catch let error as BWError {
            return .failure(error)
        }
        catch {
            return .failure(.googleDrive(underlying: error))
        }
    }

    public func save(_ budget: BWBudget, accessToken: String) async -> Result<BWBudget, BWError> {
        do {
            var budgetToUpload = budget
            let savedMetadata = metadata[budget.id]

            if let fileID = savedMetadata?.fileID {
                let remoteData = try await download(fileID: fileID, accessToken: accessToken)
                let remoteBudget = try decodeBudget(remoteData)
                budgetToUpload = try BWCRDT.merge(budget, remoteBudget).get()
                budgetToUpload = try await vault.cacheCloudBudget(budgetToUpload).get()
            }

            let folderID = savedMetadata == nil
                ? try await findOrCreateVault(accessToken: accessToken)
                : nil
            let uploaded = try await upload(
                budget: budgetToUpload,
                fileID: savedMetadata?.fileID,
                folderID: folderID,
                accessToken: accessToken
            )
            metadata[budget.id] = Metadata(
                fileID: uploaded.id,
                version: uploaded.numericVersion,
                ownerEmail: uploaded.owners?.first?.emailAddress ?? savedMetadata?.ownerEmail,
                sharedWithCurrentUser: savedMetadata?.sharedWithCurrentUser ?? false
            )
            persistMetadata()
            return .success(budgetToUpload)
        }
        catch {
            return .failure(.googleDrive(underlying: error))
        }
    }

    public func delete(_ budget: BWBudget, accessToken: String) async -> Result<Void, BWError> {
        do {
            if let fileID = metadata[budget.id]?.fileID {
                var request = try request(
                    path: "files/\(fileID)",
                    accessToken: accessToken,
                    method: "PATCH"
                )
                request.httpBody = try JSONSerialization.data(withJSONObject: ["trashed": true])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                _ = try await data(for: request, operation: "delete")
            }
            metadata.removeValue(forKey: budget.id)
            persistMetadata()
            return .success(())
        }
        catch {
            return .failure(.googleDrive(underlying: error))
        }
    }

    public func share(
        _ budget: BWBudget,
        with email: String,
        accessToken: String
    ) async -> Result<Void, BWError> {
        do {
            guard let fileID = metadata[budget.id]?.fileID else {
                throw BWError.googleDrive()
            }

            var components = URLComponents(
                string: "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions"
            )!
            components.queryItems = [URLQueryItem(name: "sendNotificationEmail", value: "true")]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "type": "user",
                "role": "writer",
                "emailAddress": email.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
            _ = try await data(for: request, operation: "sharing")
            return .success(())
        }
        catch {
            return .failure(.googleDrive(underlying: error))
        }
    }

    public func contains(_ budgetID: UUID) -> Bool {
        metadata[budgetID] != nil
    }

    public func reset() {
        metadata = [:]
        defaults.removeObject(forKey: metadataKey)
    }

    private func findOrCreateVault(accessToken: String) async throws -> String {
        let query = "name = '\(Self.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        if let folder = try await listFiles(query: query, accessToken: accessToken).first {
            return folder.id
        }

        var request = try request(path: "files", accessToken: accessToken, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": Self.folderName,
            "mimeType": "application/vnd.google-apps.folder"
        ])
        let (data, _) = try await data(for: request, operation: "folder creation")
        return try JSONDecoder().decode(Folder.self, from: data).id
    }

    private func listBudgetFiles(accessToken: String) async throws -> [RemoteFile] {
        // The user-visible Drive corpus includes My Drive and files directly shared
        // with the current user. Filtering after listing avoids excluding budgets
        // placed outside the Budget Warden folder.
        try await listFiles(
            query: "trashed = false and name contains '.budget'",
            accessToken: accessToken
        ).filter { $0.name.lowercased().hasSuffix(".budget") }
    }

    private func listFiles(query: String, accessToken: String) async throws -> [RemoteFile] {
        var files: [RemoteFile] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,version,owners(emailAddress),sharedWithMeTime)")
            ]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = items
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await data(for: request, operation: "listing")
            let page = try JSONDecoder().decode(FileList.self, from: data)
            files.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil

        return files
    }

    private func download(fileID: String, accessToken: String) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!
        components.queryItems = [URLQueryItem(name: "alt", value: "media")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await data(for: request, operation: "download").0
    }

    private func upload(
        budget: BWBudget,
        fileID: String?,
        folderID: String?,
        accessToken: String
    ) async throws -> RemoteFile {
        let encoded = try BWCodec.encodeBudget(budget: budget).get()
        let boundary = "BudgetWarden-\(UUID().uuidString)"
        var metadata: [String: Any] = [
            "name": "\(BWFiles.normalizedFileName(from: budget.title)).budget"
        ]
        if let folderID {
            metadata["parents"] = [folderID]
        }
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\nContent-Type: \(Self.budgetMIMEType)\r\n\r\n".data(using: .utf8)!)
        body.append(encoded.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let path = fileID.map { "files/\($0)" } ?? "files"
        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/\(path)")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: "id,name,version,owners(emailAddress),sharedWithMeTime")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = fileID == nil ? "POST" : "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, _) = try await data(for: request, operation: "upload")
        return try JSONDecoder().decode(RemoteFile.self, from: data)
    }

    private func decodeBudget(_ data: Data) throws -> BWBudget {
        guard let json = String(data: data, encoding: .utf8) else {
            throw BWError.decodingJson()
        }
        return try BWCodec.decodeBudget(
            json: json,
            url: URL(fileURLWithPath: "/GoogleDriveRemote.budget")
        ).get()
    }

    private func request(
        path: String,
        accessToken: String,
        method: String = "GET"
    ) throws -> URLRequest {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/\(path)") else {
            throw BWError.googleDrive()
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func data(
        for request: URLRequest,
        operation: String
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            let http = response as? HTTPURLResponse
            throw HTTPFailure(
                operation: operation,
                statusCode: http?.statusCode ?? 0,
                response: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return (data, response)
    }

    private func persistMetadata() {
        if let data = try? JSONEncoder().encode(metadata) {
            defaults.set(data, forKey: metadataKey)
        }
    }
}
