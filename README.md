# LogM8 — Android build

Builds the **LogM8** Android app (package `au.com.logm8.app`) as a signed App Bundle (AAB) for Google Play.

The app is a Capacitor 8 shell around the live web app: `build.sh` downloads
`https://www.logm8.com.au/app.html` (+ icons, manifest, templates) at build time, so this repository
contains **no application code** — only the wrapper configuration, launcher/splash artwork and CI.

## Build (GitHub Actions)
Actions → **Build LogM8 Android AAB** → *Run workflow*. Optional inputs: `version_name`, `version_code`
(blank = `10 + run number`). The signed `.aab` is attached to the run as an artifact and to a GitHub Release
tagged `build-<run number>`.

Secrets used: `KEYSTORE_B64` (upload keystore, base64), `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`,
`RC_ANDROID_KEY` (RevenueCat Android public key — optional; without it native subscriptions are disabled).

## Build locally
Needs Node 22, JDK 21 and the Android SDK (platform 36, build-tools 36).
```
export VERSION_NAME=1.5.29 VERSION_CODE=11
export KEYSTORE_B64=$(base64 -w0 logm8-upload.jks) KEYSTORE_PASSWORD=... KEY_PASSWORD=... KEY_ALIAS=logm8upload
bash build.sh
# -> android/app/build/outputs/bundle/release/app-release.aab
```
