# Budget Warden

Budget Warden is a source-available native Apple budgeting app. It stores budgets as plain `.budget` files.

## Requirements

- macOS
- Xcode

## Development

Xcode workspace:

```sh
open BudgetWarden.xcworkspace
```

### Google Drive on Apple platforms

The iOS and macOS targets use Google Sign-In 9.2 and the Google Drive v3 API. Before running either target:

1. Enable the Google Drive API in the app's Google Cloud project.
2. Create an OAuth client for bundle ID `com.lazarovco.budgetwarden` and add the full Drive scope (`https://www.googleapis.com/auth/drive`) to the OAuth consent screen.
3. Set `GOOGLE_CLIENT_ID` and `GOOGLE_REVERSED_CLIENT_ID` as user-defined build settings on both Apple app targets. [GoogleDriveConfiguration.xcconfig.example](GoogleDriveConfiguration.xcconfig.example) shows the expected values.

The full Drive scope is required because Budget Warden discovers `.budget` files throughout the user's visible Drive corpus, including files shared with the user. Production distribution may require Google OAuth verification for this scope.

## License

This repository is source-available for educational, research, and reference purposes only. Building, running, using, redistributing, or commercially using the software requires a valid commercial license from Lazarov & Co EOOD.

See [LICENSE](LICENSE) for the full terms.
