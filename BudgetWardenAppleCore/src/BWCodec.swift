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
        encoder.outputFormatting = .prettyPrinted
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

        return .success(decodedBudget)
    }
}
