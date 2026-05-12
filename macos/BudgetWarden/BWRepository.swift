import Foundation

class BWRepository {
    static func createBudget(
        title: String,
        template: BudgetTemplateSelection,
        vault: BWVault
    ) -> Result<BWBudget, BWError> {
        if vault.url == nil {
            return .failure(.creatingBudget)
        }

        var budget: BWBudget;

        switch template {
            case .basic:
                budget = BWTemplate.basicBudget(title: title) 
                break
            case .blank:
                budget = BWBudget(title: title)
                break
            case .previous(let url):
                // @TODO(Niki): Not yet implemented
                budget = BWBudget(title: title)
                break
        }

        do {
            let fileUrl = try makeUniqueBudgetFileURL(
                directoryURL: vault.url!,
                title: title
            )

            let jsonRes = BWCodec.encodeBudget(budget: budget)

            var json: String = "";

            switch jsonRes {
                case .failure:
                    return .failure(.creatingBudget)
                case .success(let resJson):
                   json = resJson 
            }
 
            let saveFileRes = BWFiles.saveFile(url: fileUrl, json: json)

            budget.url = fileUrl

            return .success(budget)
        }
        catch {
            return .failure(.creatingBudget)
        }
    }

    private static func makeUniqueBudgetFileURL(
        directoryURL: URL,
        title: String
    ) throws -> URL {
        let baseName = normalizedFileName(from: title)
        let fileExtension = "budget"

        var candidateURL = directoryURL
            .appendingPathComponent(baseName)
            .appendingPathExtension(fileExtension)

        var index = 2

        while FileManager.default.fileExists(atPath: candidateURL.path) {
            candidateURL = directoryURL
                .appendingPathComponent("\(baseName) \(index)")
                .appendingPathExtension(fileExtension)

            index += 1
        }

        return candidateURL
    }

    private static func normalizedFileName(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)

        let cleaned = trimmed
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "Untitled Budget" : cleaned
    }
}
