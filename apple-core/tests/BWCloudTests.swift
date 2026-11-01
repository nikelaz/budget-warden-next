import Foundation
import Testing
@testable import BWAppleCore

@Suite("Cloud budgets")
struct BWCloudTests {
    @Test("Cloud errors drop the core's sign-in marker")
    func cloudErrorsDropTheSignInMarker() {
        let signIn = BWCloudError(FfiError(message: "SIGN_IN_REQUIRED: Sign in to Google Drive to sync your budgets."))
        #expect(signIn.requiresSignIn)
        #expect(signIn.localizedDescription == "Sign in to Google Drive to sync your budgets.")

        let other = BWCloudError(FfiError(message: "Google Drive is busy. Please try again in a moment."))
        #expect(!other.requiresSignIn)
        #expect(other.message == "Google Drive is busy. Please try again in a moment.")
        #expect(BWCloudError(signIn).requiresSignIn)
    }

    @Test("Google Drive budgets describe who shared them")
    func googleDriveLocationDescriptions() {
        var budget = BWCloudBudget(
            id: "1",
            name: "Home.budget",
            title: "Home",
            ownerName: "Ana",
            ownerEmail: "ana@example.com",
            sharedWithMe: false,
            isShared: false,
            canEdit: true,
            canShare: true,
            modifiedTime: nil,
            webLink: nil,
            localPath: nil
        )
        #expect(budget.locationDescription == "Google Drive")
        budget.isShared = true
        #expect(budget.locationDescription == "Google Drive · Shared")
        budget.sharedWithMe = true
        #expect(budget.locationDescription == "Shared by Ana")
        budget.canEdit = false
        budget.ownerName = nil
        #expect(budget.locationDescription == "Shared by ana@example.com · View only")
    }

    @Test("iCloud budgets describe who shared them")
    func iCloudLocationDescriptions() {
        var budget = BWICloudBudget(
            url: URL(fileURLWithPath: "/tmp/Home.budget"),
            title: "Home",
            isShared: false,
            isSharedWithMe: false,
            ownerName: nil,
            isReadOnly: false,
            isDownloaded: true,
            modificationDate: nil
        )
        #expect(budget.locationDescription == "iCloud Drive")
        budget.isShared = true
        #expect(budget.locationDescription == "iCloud Drive · Shared")
        budget.isSharedWithMe = true
        budget.ownerName = "Ben"
        budget.isReadOnly = true
        #expect(budget.locationDescription == "Shared by Ben · View only")
    }

    @Test("Builds without a Google client ID are not configured")
    @MainActor
    func unconfiguredBuilds() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("BWCloudTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let controller = BWGoogleDriveController(
            clientID: "$(BW_GOOGLE_CLIENT_ID)",
            pickerURL: "$(BW_GOOGLE_PICKER_URL)",
            cacheDirectory: cache,
            keychainService: "com.lazarovco.budgetwarden.tests.\(UUID().uuidString)",
            budgetDidChange: { _ in }
        )
        #expect(!controller.isConfigured)
        #expect(!controller.canAddSharedBudgets)
        #expect(!controller.isSignedIn)
        #expect(controller.budgets.isEmpty)
        #expect(controller.budgetID(for: cache.appendingPathComponent("x.budget")) == nil)
    }

    @Test("Apple redirect URIs use the reversed client ID")
    func appleRedirectURIs() {
        let clientID = "1234-abc.apps.googleusercontent.com"
        #expect(googleAppleCallbackScheme(clientId: clientID) == "com.googleusercontent.apps.1234-abc")
        #expect(googleAppleRedirectUri(clientId: clientID) == "com.googleusercontent.apps.1234-abc:/oauth2redirect")
    }

    @Test("Files without iCloud conflicts are left alone")
    func filesWithoutConflicts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BWCloudTests-\(UUID().uuidString).budget")
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try BWICloudBudgetLibrary.resolveConflicts(at: url) == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{}")
    }

    @Test("The URLSession client rejects malformed URLs")
    func malformedURLs() {
        let client = BWURLSessionHTTPClient()
        #expect(throws: FfiError.self) {
            try client.execute(request: BWHttpRequest(method: "GET", url: "", headers: [], body: nil))
        }
    }
}
