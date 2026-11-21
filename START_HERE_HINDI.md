# CampusVibe — ek jagah par steps (21 November 2026)

**Status:** Source code Google-only login ke UI ke saath hai. **Live working APK abhi nahi bana.** Neon `CampusVibe Pilot` database mein tables verified hain. GitHub account `monu-gaurav` mein repository nahi mili; Render workspace `Monu's workspace` mein web service nahi mili. Google OAuth ke Android + Web client IDs configure/verify nahi hue. Tests/android APK live run nahi hue.

## Step 1: GitHub par empty PRIVATE repository

1. Open https://github.com/new and sign in as `monu-gaurav`.
2. Repository name **CampusVibe**; **Private** choose karo.
3. README, .gitignore, license auto-add **mat** karo, kyunki ZIP me files hain.
4. `Create repository` dabao.
5. ZIP extract kar ke `CampusVibe` folder me PowerShell kholo aur command chalao:

```powershell
.\PUSH_TO_GITHUB.ps1 -RepoUrl 'https://github.com/monu-gaurav/CampusVibe.git'
```

Push ke liye Git for Windows aur GitHub sign-in zaroori ho sakta hai. Ye command app deploy **nahi** karti.

## Step 2: Render deploy

1. https://dashboard.render.com/ par **Monu's workspace** select karo.
2. **New > Blueprint** mein `CampusVibe` GitHub repository link karo. Repo root me `render.yaml` hai; free plan declare hai.
3. `DATABASE_URL` ke liye **existing Neon `CampusVibe Pilot`** ka TLS connection string Neon dashboard se Render environment variable mein paste karo; ChatGPT ya GitHub mein public paste **mat** karo.
4. Render-generated JWT/moderation secrets secure rakho. Successful deploy ke baad HTTPS URL aur `/health` check karo.
5. Free web service sleep ho sakti hai, isliye always-on instant messaging guaranteed nahi hai.

## Step 3: Google login configure karo

1. Google Cloud Console > Google Auth Platform mein OAuth consent screen/branding setup karo.
2. App package: `com.campusvibe.campusvibe`. APK signing key ka SHA-1 register kar ke **Android OAuth client** banao.
3. Usi Cloud project me **Web OAuth client** banao. Iska **client ID** Render service env `GOOGLE_WEB_CLIENT_ID` mein add karo. **Client secret APK/GitHub mein mat daalna.**
4. Backend redeploy; `https://YOUR-RENDER-URL/mobile/config` mein `google_client_id` aana chahiye. Google login phone par test karo.

## Step 4: APK build

1. APK signing key ko private rakho; GitHub Actions repository secrets: `CAMPUS_KEYSTORE_B64`, `CAMPUS_STORE_PASSWORD`, `CAMPUS_KEY_PASSWORD`, `CAMPUS_KEY_ALIAS`.
2. GitHub repository > Actions > `Build CampusVibe student APK` > Run workflow; `api_origin` me **real HTTPS Render service origin** daalo.
3. Workflow Flutter tests + Android build chalayega. Green/success hone par `CampusVibe-Student-APK` artifact se APK download karo.
4. Do phones par registration, Google sign-in, live chat, offline message delivery, photo/PDF share, reconnect aur security test karo. **Unverified build ko fully functional mat samajhna.**

## Current limitations

- Ye ZIP **source** hai, APK nahi. Uploaded original APK abhi bhi purana hai.
- Flutter/Android SDK is environment me installed nahi tha, isliye local release APK compile/test nahi hua.
- Backend Python integration tests me dependencies missing thi, isliye green result nahi mila.
- Files database me store ho sakti hain; Neon free storage limits rapidly fill ho sakti hain. Push notifications/true WhatsApp-grade uptime aur scalability ki guarantee nahi.
- Existing app ka email/password API abhi backend mein hai; student Flutter login screen Google-only hai.
