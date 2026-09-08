#!/usr/bin/env bash
# LogM8 Android build
# Wraps the live LogM8 web app (https://www.logm8.com.au/app.html) in a Capacitor 8 shell
# and builds a signed Android App Bundle (AAB) ready for the Play Console.
#
# Inputs (environment variables):
#   VERSION_NAME       versionName shown to users            (default 1.5.29)
#   VERSION_CODE       integer, must increase every upload   (default 11)
#   SITE_URL           where the web app is fetched from     (default https://www.logm8.com.au)
#   KEYSTORE_B64       base64 of the upload keystore (.jks)  -> signed release
#   KEYSTORE_PASSWORD  keystore password
#   KEY_ALIAS          key alias                              (default logm8upload)
#   KEY_PASSWORD       key password
#   RC_ANDROID_KEY     RevenueCat Android public API key (goog_...) -> enables native subscriptions
#
# Output: android/app/build/outputs/bundle/release/app-release.aab
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SITE="${SITE_URL:-https://www.logm8.com.au}"
VERSION_NAME="${VERSION_NAME:-1.5.29}"
VERSION_CODE="${VERSION_CODE:-11}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36 LogM8-Build"

echo "== LogM8 Android build: versionName=$VERSION_NAME versionCode=$VERSION_CODE"

echo "== 1/6 npm dependencies"
if [ -f package-lock.json ]; then npm ci --no-audit --no-fund; else npm install --no-audit --no-fund; fi

echo "== 2/6 web bundle from $SITE"
rm -rf www && mkdir -p www/vendor
fetch() {
  if curl -fsSL -A "$UA" --retry 3 --retry-delay 2 "$SITE/$1" -o "www/$2"; then
    echo "   $1 -> www/$2 ($(stat -c%s "www/$2") bytes)"
  else
    echo "   WARNING: could not fetch $1"; rm -f "www/$2"; return 1
  fi
}
fetch app.html index.html
# Static files the app references. No sw.js on purpose: a service worker inside the
# native shell would pin an old index.html across app updates.
for f in manifest.json icon-logm8-v2-192.png icon-logm8-v2-512.png icon-logm8-v2-180.png \
         favicon-32.png favicon-16.png logo-report.png logo-report.svg logbook-template.xlsx \
         version.json health.json privacy.html delete-account.html; do
  fetch "$f" "$f" || true
done
grep -q "LOGM8_APP_CACHE_VERSION" www/index.html || { echo "ERROR: www/index.html is not the LogM8 app"; exit 1; }

echo "== 3/6 native tweaks"
# The app does `await import('@revenuecat/purchases-capacitor')` (a bare specifier). Bundle the
# plugin as a single ESM file and map the specifier to it with an import map.
npx esbuild node_modules/@revenuecat/purchases-capacitor/dist/esm/index.js \
  --bundle --format=esm --platform=browser --log-level=warning \
  --outfile=www/vendor/purchases-capacitor.js
RC_ANDROID_KEY="${RC_ANDROID_KEY:-}" python3 - <<'PY'
import os, re
p = 'www/index.html'
s = open(p, encoding='utf-8').read()
importmap = ('<script type="importmap">{"imports":{"@revenuecat/purchases-capacitor":'
             '"./vendor/purchases-capacitor.js"}}</script>')
if 'type="importmap"' not in s:
    s = re.sub(r'(<head[^>]*>)', lambda m: m.group(1) + '\n' + importmap, s, count=1)
    print('   import map injected')
key = os.environ.get('RC_ANDROID_KEY', '').strip()
pat = r"(const\s+RC_ANDROID_KEY\s*=\s*)'YOUR_REVENUECAT_ANDROID_KEY'"
if key.startswith('goog_'):
    s, n = re.subn(pat, lambda m: m.group(1) + "'" + key + "'", s, count=1)
    print('   RevenueCat key injected' if n else '   WARNING: RC_ANDROID_KEY placeholder not found')
else:
    print('   RevenueCat key not provided -> native purchases disabled in this build')
open(p, 'w', encoding='utf-8').write(s)
PY
cp www/index.html www/app.html   # the app links to /app.html in a few places
echo "   web bundle: $(du -sh www | cut -f1)"

echo "== 4/6 Capacitor Android project"
rm -rf android
npx cap add android
cp -f overlay-AndroidManifest.xml android/app/src/main/AndroidManifest.xml
sed -e "s/__VERSION_CODE__/${VERSION_CODE}/" -e "s/__VERSION_NAME__/${VERSION_NAME}/" \
    overlay-app-build.gradle > android/app/build.gradle
if [ -n "${KEYSTORE_B64:-}" ]; then
  echo "$KEYSTORE_B64" | tr -d '\n\r ' | base64 -d > android/app/upload.jks
  {
    echo "storeFile=upload.jks"
    echo "storePassword=${KEYSTORE_PASSWORD:?KEYSTORE_PASSWORD missing}"
    echo "keyAlias=${KEY_ALIAS:-logm8upload}"
    echo "keyPassword=${KEY_PASSWORD:?KEY_PASSWORD missing}"
  } > android/keystore.properties
  echo "   signing: release keystore configured"
else
  echo "   signing: no keystore -> UNSIGNED bundle (Play will reject it)"
fi
npx cap sync android

echo "== 5/6 launcher icons and splash"
npx @capacitor/assets generate --android --assetPath resources \
  --iconBackgroundColor '#0a0a0a' --iconBackgroundColorDark '#0a0a0a' \
  --splashBackgroundColor '#0a0a0a' --splashBackgroundColorDark '#0a0a0a'

if [ "${SKIP_GRADLE:-}" = "1" ]; then echo "== SKIP_GRADLE=1, stopping before Gradle"; exit 0; fi

echo "== 6/6 gradle bundleRelease"
cd android
chmod +x gradlew
./gradlew bundleRelease --no-daemon --stacktrace
echo "== DONE"
ls -la app/build/outputs/bundle/release/
