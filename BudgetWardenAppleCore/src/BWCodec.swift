/* 
 * Budget Warden
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

import Foundation

nonisolated public final class BWCodec {
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encodeBudget(budget: BWBudget) -> Result<String, BWError> {
        let data: Data

        do {
            data = try Self.makeEncoder().encode(budget)
        }
        catch {
            return .failure(BWError.encodingJson(underlying: error))
        }
 
        guard let json = String(data: data, encoding: .utf8) else { 
            return .failure(BWError.encodingJson())
        }
        
        return .success(json)
    }

    public static func decodeBudget(json: String, url: URL) -> Result<BWBudget, BWError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(.decodingJson())
        }
        
        let budget: BWBudget

        do {
            budget = try Self.makeDecoder().decode(BWBudget.self, from: data)
        }
        catch {
            return .failure(.decodingJson(underlying: error))
        }
        
        var decodedBudget = budget
        decodedBudget.url = url

        if decodedBudget.revision == nil {
            decodedBudget.revision = 0
        }

        if decodedBudget.crdt == nil,
           (decodedBudget.schemaVersion == nil
            || decodedBudget.schemaVersion == 1
            || decodedBudget.schemaVersion == BWCRDT.schemaVersion) {
            // Older clients can write schema-v2-shaped budgets without CRDT state.
            // Treat those documents as legacy snapshots so they remain readable.
            decodedBudget = BWCRDT.migrateLegacy(decodedBudget)
            decodedBudget.url = url
        } else if decodedBudget.schemaVersion == BWCRDT.schemaVersion,
                  decodedBudget.crdt != nil {
            decodedBudget = BWCRDT.materialize(decodedBudget)
            decodedBudget.url = url
        } else {
            return .failure(.decodingJson())
        }

        return .success(decodedBudget)
    }
}
