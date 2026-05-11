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

struct BWCodec {
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
        guard let data = try? Self.encoder.encode(budget) else {
            return .failure(BWError.encodingJson)
        }
        
        guard let json = String(data: data, encoding: .utf8) else { 
            return .failure(BWError.encodingJson)
        }
        
        return .success(json)
    }

    static func decodeBudget(json: String) -> Result<BWBudget, BWError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(.decodingJson)
        }

        guard let budget = try? Self.decoder.decode(BWBudget.self, from: data) else {
            return .failure(.decodingJson)
        }

        return .success(budget)
    }
}
