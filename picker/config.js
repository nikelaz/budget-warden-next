// Fill these in before deploying the picker page. All three come from the
// same Google Cloud project as the apps' OAuth clients, because drive.file
// access granted here belongs to that project.
window.BUDGET_WARDEN_PICKER = {
  // OAuth client of type "Web application". Add this page's URL to its
  // authorized redirect URIs and its origin to the JavaScript origins.
  clientId: "WEB_CLIENT_ID.apps.googleusercontent.com",
  // API key restricted to the Google Picker API and to this page's origin.
  apiKey: "API_KEY",
  // The Cloud project number (Project settings → Project number).
  appId: "PROJECT_NUMBER",
};
