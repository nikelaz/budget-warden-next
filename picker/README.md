# Shared-budget picker page

Budget Warden uses the `drive.file` Google Drive scope: it can only reach files it created and files the user chooses for it in the [Google Picker](https://developers.google.com/drive/picker). The Picker is a web component, so every app opens this static page in a browser when the user chooses **Add Shared Budget**, and invitation emails link to it with the shared budget preselected.

The page signs the user in with Google (redirect flow, so it also works inside `ASWebAuthenticationSession` and Android browser tabs), shows the Picker, and returns the chosen file IDs to the app:

- `return_to=http://127.0.0.1:PORT/…` (Windows, Linux, CLI) or `return_to=com.googleusercontent.apps.ID:/picked` (macOS, iOS): the page redirects there with `?ids=ID1,ID2`, `?cancelled=1`, or `?error=…`. Other `return_to` values are ignored.
- No `return_to` (Android, links in emails): the page tells the user to return to the app, which finds the budget on its next refresh.
- `file=ID` preselects a budget; `login_hint=EMAIL` suggests the account.

## Deploy

1. In the Google Cloud project that holds the apps' OAuth clients, enable the **Google Picker API**.
2. Create an OAuth client of type **Web application**. Add the page's origin to *Authorized JavaScript origins* and the page URL (for example `https://budgetwarden.example/pick/`) to *Authorized redirect URIs*.
3. Create an **API key** restricted to the Google Picker API and to the page's HTTP referrer.
4. Fill in `config.js` with the web client ID, the API key, and the project **number** (not ID). The project number makes Google grant access to every client in that project, including the desktop, Apple, and Android clients.
5. Host the directory over HTTPS (GitHub Pages, Cloudflare Pages, or any static host) and give its URL to the app builds as the picker URL (see `docs/cloud-sync.md`).
