# Version 0.3 verification

The eleven API workflow tests run against both disposable SQLite and PostgreSQL databases. Coverage includes the existing study, dating, verification, chat, book, circle and file flows plus Google-created account persistence, verified email status, college-gate enforcement, a conflicting password account and missing provider configuration. Google tests inject controlled identity claims. Live Google account selection and live email delivery require operator-owned provider configuration.

Flutter tests cover the initial pilot enrollment screen and HTTPS origin validation. The APK was built for ARM64 using the Flutter profile build type. Physical installation, a public two-phone mobile-data session, free-host cold starts, provider quotas, real Google credential validation and GitHub-hosted release signing must be tested after deployment. The build does not include FCM or national-scale load testing.

Backend command: python -m pytest -q from backend. CAMPUS_TEST_DATABASE_URL may point at a dedicated disposable PostgreSQL database. Tests reset tables; never use a production URL. Flutter command: flutter test from mobile.
