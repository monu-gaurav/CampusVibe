# Development, deployment and release

## Local and hosted services

Use a fresh database for this edition. Older unversioned starter databases need a schema and backup review before migration. Never run tests with a production database URL. The API tests drop and recreate tables in the selected test database.

The Windows launcher sets two separate random local secrets and enables file-based development mail. For hosting, generate independent secrets, set the variables in backend/.env.example using a service manager or secret store and leave LOCAL_MAIL unset. The application reads process environment variables. SMTP uses authenticated STARTTLS. Use a private PostgreSQL database and private Redis endpoint. The Android profile build permits cleartext only to the named loopback development hosts. Expose the hosted API through HTTPS and support WebSocket upgrade at /live/. Restrict the moderation page to operators. Replace the shared moderator credential with individual MFA-protected operator identities for a public launch.

From the backend directory with dependencies installed, run:

```shell
python -m alembic upgrade head
python -m uvicorn main:app --host 127.0.0.1 --port 8000
```

Place the TLS proxy in front of this listener. Configure request-size limits, database backups, encrypted storage, log redaction, mail delivery, monitoring and operational deletion procedures. Private attachments are stored in SQL and authorized for each download. JPEG/PNG uploads are decoded and re-encoded. PDFs are parsed, constrained and rewritten. Production needs isolated file scanning and load tests. WebSockets fetch recent state periodically and are intended for small pilot testing. No national-scale capacity or ₹0 hosted-service guarantee has been established.

## Repeatable checks

Run from backend: `python -m pytest -q`. The suite uses disposable SQLite by default. To test PostgreSQL, set CAMPUS_TEST_DATABASE_URL to a dedicated throwaway database. Run from mobile: `flutter pub get`, then `flutter test`. Test the physical phone picker, downloads, camera permissions where applicable, poor connectivity and account switching before distribution. Initial demo data is created only by automated tests or explicit signup.

## APK and Android App Bundle

The source targets Flutter 3.35.7, Gradle 8.12, Android Gradle Plugin 8.9.1 and JDK 17. From mobile:

```powershell
flutter pub get
flutter build apk --profile --target-platform android-arm64 --split-per-abi --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

The downloadable profile APK uses a development signature and ARM64 native code. For production set CAMPUS_KEYSTORE to an absolute path to your own upload keystore, plus CAMPUS_STORE_PASSWORD, CAMPUS_KEY_ALIAS and CAMPUS_KEY_PASSWORD. Keep these out of source control. Set the deployed HTTPS endpoint and run:

```powershell
flutter build appbundle --release --dart-define=API_BASE_URL=https://YOUR-API-DOMAIN
```

Use `flutter build apk --release` with the same API definition for a release APK. The AAB output is build/app/outputs/bundle/release/app-release.aab. Only the development APK was requested as a binary. Production signing and store submission are operator steps.

## Play release checklist

- Establish institution enrollment agreements, the adult-verification process and moderator staffing.
- Review age targeting and dating functionality, publish child-safety standards, assign a child-safety contact and implement abuse response and escalation. Review Google's current [child safety standards](https://support.google.com/googleplay/android-developer/answer/14747720) and [age-restricted functionality](https://support.google.com/googleplay/android-developer/answer/16302250).
- Publish the privacy notice, data retention schedule and external account deletion page. Verify deletion and exports for database rows, attachments, caches and backups. Complete the Data safety disclosure. Review Google's [account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111).
- Have the operator review the actual collection, consent, grievance handling and age workflows against applicable Indian privacy requirements. No compliance certification is included.
- Choose the final application ID, sign and back up the upload key, verify current target SDK policy, complete content rating and prepare listing assets.
- Complete internal and closed testing with real devices, multiple accounts and independent networks. Verify installed builds, event times, access revocation, file types, delivery failures and backup restoration.
- Review security and performance findings, configure abuse controls, confirm service costs and use a staged rollout.
