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

nonisolated class BWCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func encodeBudget(budget: BWBudget) -> Result<String, BWError> {
        let data: Data

        do {
            data = try Self.encoder.encode(budget)
        }
        catch {
            return .failure(BWError.encodingJson(underlying: error))
        }
 
        guard let json = String(data: data, encoding: .utf8) else { 
            return .failure(BWError.encodingJson())
        }
        
        return .success(json)
    }

    static func decodeBudget(json: String, url: URL) -> Result<BWBudget, BWError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(.decodingJson())
        }
        
        var budget: BWBudget

        do {
            budget = try Self.decoder.decode(BWBudget.self, from: data)
        }
        catch {
            return .failure(.decodingJson(underlying: error))
        }
        
        budget.url = url

        return .success(budget)
    }
}

