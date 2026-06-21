import OSLog
import AppleCore

private let logger = Logger(
    subsystem: "com.lazarov.budgetwarden",
    category: "BudgetWarden"
)

func bwLog(_ error: BWError) {
    logger.error("BWError: \(error.localizedDescription, privacy: .public)")

    if let underlying = error.underlyingError {
        logger.error("Underlying error: \(String(describing: underlying), privacy: .private)")
    }
}
