# Connect Google Sign-In

1. In a Google Cloud project you own, configure the Google Auth Platform branding, support email and audience. For an external app in Testing, add your pilot students as test users.
2. Create an **Android OAuth client**. The Android package name is **com.campusvibe.campusvibe**. Use the SHA-1 certificate fingerprint of the APK students will actually install. Each different development, upload or Play App Signing certificate needs its corresponding Android client.
3. In the same Google Cloud project create a **Web application OAuth client**. Copy its public client ID, ending in apps.googleusercontent.com, into the backend environment as GOOGLE_WEB_CLIENT_ID. The Android ID is not the web ID. No Google client secret is needed for this native ID-token exchange.
4. Redeploy the API. Confirm /mobile/config returns the configured public web client ID. On a phone with Google Play services, open the app, enter the pilot HTTPS address if prompted and choose **Continue with Google**. Check profile completion, college approval and sign-in again after logout.
5. To inspect the public fingerprint of a downloaded APK, use Android Build Tools `apksigner verify --print-certs CampusVibe_0_3_Internet_Pilot.apk`. For Google Play distribution, obtain the Play App Signing certificate from Play Console. Do not share your keystore.

Provider reference: https://developers.google.com/identity/gsi/web/guides/verify-google-id-token

Included 0.3 pilot APK certificate SHA-1: 1D:38:75:B2:ED:65:6D:81:BE:79:84:D1:84:6C:12:45:50:BC:26:42
