# CampusVibe Google-only login source update

This source change removes the *manual HTTPS server address form* and the visible email/password login. The student now sees **Sign in with Google**. It does **not** remove HTTPS: authenticated client-server calls still require TLS.

## What is verified
- The preexisting Flutter project has a `google_sign_in` dependency, and FastAPI has `/auth/google` validating Google ID tokens against `GOOGLE_WEB_CLIENT_ID`.
- The login UI is updated to be Google-only; the server URL must be bundled at build time with `--dart-define=API_BASE_URL=https://your-real-host`.
- The GitHub Actions workflow now requires the backend to return a public Google OAuth web client ID.
- **An Android APK was NOT built or tested** in this environment (Flutter and Android SDK absent). The original user-uploaded APK is unchanged.

## Before making an APK
1. Deploy the existing `backend` on a real HTTPS host; connect its PostgreSQL `DATABASE_URL` to Neon.
2. Register `com.campusvibe.campusvibe` plus the SHA-1 of your final APK's *signing certificate* as an Android OAuth client in Google Cloud; create a Web OAuth client in that same Google Cloud project.
3. Put the Web OAuth client ID, *not the Android OAuth client ID*, into Render as `GOOGLE_WEB_CLIENT_ID` and redeploy.
4. From `mobile/` run: `flutter pub get`, `flutter test`, then `flutter build apk --release --dart-define=API_BASE_URL=https://YOUR-RENDER-SERVICE.onrender.com` with your signing configuration.
5. Validate on two real Android phones before distribution. Hosting, OAuth, push notifications, and real-time behavior have not been independently verified.

The original APK is **not automatically replaced** by this ZIP. Don't distribute it as a Google-only release.
