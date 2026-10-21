/*
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License.
 * See the LICENSE file in the project root for full terms.
 */

import BWCore
import Foundation
import Security

/// Performs the core's Google Drive requests with `URLSession`. The core calls
/// it from background threads only, so blocking until the response arrives is
/// safe.
public final class BWURLSessionHTTPClient: BWHttpClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(request: BWHttpRequest) throws -> BWHttpResponse {
        guard let url = URL(string: request.url) else {
            throw FfiError(message: "Invalid request URL.")
        }
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        urlRequest.httpMethod = request.method
        for header in request.headers {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        urlRequest.httpBody = request.body.map { Data($0.utf8) }

        let completion = BWBlockingResult<(Data, HTTPURLResponse)>()
        session.dataTask(with: urlRequest) { data, response, error in
            if let error {
                completion.finish(.failure(error))
            } else if let response = response as? HTTPURLResponse {
                completion.finish(.success((data ?? Data(), response)))
            } else {
                completion.finish(.failure(URLError(.badServerResponse)))
            }
        }.resume()

        do {
            let (data, response) = try completion.wait()
            let headers = response.allHeaderFields.compactMap { key, value -> BWHttpHeader? in
                guard let name = key as? String else { return nil }
                return BWHttpHeader(name: name, value: "\(value)")
            }
            return BWHttpResponse(
                status: Int32(response.statusCode),
                headers: headers,
                body: String(decoding: data, as: UTF8.self)
            )
        } catch {
            throw FfiError(message: "Could not reach Google Drive: \(error.localizedDescription)")
        }
    }
}

/// A value produced on another thread, waited for synchronously.
private final class BWBlockingResult<Value>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func finish(_ result: Result<Value, Error>) {
        lock.withLock { self.result = result }
        semaphore.signal()
    }

    func wait() throws -> Value {
        semaphore.wait()
        return try lock.withLock { result! }.get()
    }
}

/// Keeps the Google sign-in in the Keychain.
public final class BWKeychainCredentialStore: BWGoogleCredentialStore, @unchecked Sendable {
    private let service: String
    private let account = "google-drive"

    public init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadCredentials() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func saveCredentials(credentials: String) throws {
        let data = Data(credentials.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            return
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FfiError(message: "Could not save the Google sign-in to the Keychain (\(status)).")
        }
    }

    public func deleteCredentials() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Coordinated reads and writes of budget files that other processes, such
/// as the iCloud daemon, may also be using.
enum BWCoordinatedFile {
    static func read(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            result = Result { try Data(contentsOf: $0) }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw FfiError(message: "Could not read \(url.lastPathComponent).")
        }
        return try result.get()
    }

    static func write(_ data: Data, to url: URL, replacing: Bool = true) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: replacing ? .forReplacing : [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: replacing ? .atomic : .withoutOverwriting)
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let writeError {
            throw writeError
        }
    }

    static func readBudget(_ url: URL, location: URL? = nil) throws -> BWBudget {
        try decodeBudget(
            json: String(decoding: read(url), as: UTF8.self),
            url: (location ?? url).path
        )
    }
}

/// An error from cloud storage, with the core's sign-in marker removed.
public struct BWCloudError: LocalizedError, Sendable {
    public let message: String
    /// The user has to sign in to Google Drive again.
    public let requiresSignIn: Bool

    public init(_ error: Error) {
        if let error = error as? BWCloudError {
            self = error
            return
        }
        let raw = (error as? FfiError)?.message ?? error.localizedDescription
        requiresSignIn = isCloudSignInRequired(message: raw)
        message = cloudErrorMessage(message: raw)
    }

    public init(message: String) {
        self.message = message
        requiresSignIn = false
    }

    public var errorDescription: String? { message }
}
