#!/usr/bin/env bash
# LogM8 Android build
# Wraps the live LogM8 web app (https://www.logm8.com.au/app.html) in a Capacitor 8 shell
# and builds a signed Android App Bundle (AAB) ready for the Play Console.
#
# Inputs (environment variables):
#   VERSION_NAME       versionName shown to users            (default 1.5.29)
#   VERSION_CODE       integer, must increase every upload   (default 11)
#   SITE_URL           where the web app is fetched from     (default https://www.logm8.com.au)
#   WEB_SOURCE         auto | site | snapshot  (default auto: live site first, then web-snapshot/
#                      when SiteGround's anti-bot challenge blocks the runner)
#   KEYSTORE_B64       base64 of the upload keystore (.jks)  -> signed release
#   KEYSTORE_PASSWORD  keystore password
#   KEY_ALIAS          key alias                              (default logm8upload)
#   KEY_PASSWORD       key password
#   RC_ANDROID_KEY     RevenueCat Android public API key (goog_...) -> enables native subscriptions
#   GOOGLE_SERVICES_JSON_B64  base64 of google-services.json (optional; a google-services.json committed
#                      next to this script is used otherwise) -> enables native Google Sign-In
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
# SiteGround's anti-bot layer sometimes answers data-centre IPs (GitHub runners) with a tiny
# 200 page instead of the file. Use browser-like headers, rotate user agents, fall back to the
# non-www host and retry with backoff. Anything that is not the real app is rejected.
UAS=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
  "$UA"
)
HOSTS=("$SITE" "${SITE_ALT:-https://logm8.com.au}")
get() { # get <url> <out>
  curl -fsSL -A "$UA" --retry 2 --retry-delay 3 --max-time 60 \
       -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
       -H "Accept-Language: en-AU,en;q=0.9" -H "Referer: $SITE/" "$1" -o "$2"
}
fetch_app() {
  local attempt host
  for attempt in 1 2; do
    for host in "${HOSTS[@]}"; do
      for UA in "${UAS[@]}"; do
        if get "$host/app.html" www/index.html 2>/dev/null && grep -q "LOGM8_APP_CACHE_VERSION" www/index.html; then
          SITE="$host"
          echo "   app.html -> www/index.html ($(stat -c%s www/index.html) bytes) from $host"
          return 0
        fi
        echo "   not the app from $host [UA ${UA:0:24}...] ($(stat -c%s www/index.html 2>/dev/null || echo 0) bytes):"
        echo "   >> $(head -c 200 www/index.html 2>/dev/null | tr '\r\n' '  ')"
        rm -f www/index.html
      done
    done
    [ "$attempt" = 1 ] && { echo "   waiting 20s before retry..."; sleep 20; }
  done
  return 1
}
fetch() {
  if get "$SITE/$1" "www/$2"; then
    echo "   $1 -> www/$2 ($(stat -c%s "www/$2") bytes)"
  else
    echo "   WARNING: could not fetch $1"; rm -f "www/$2"; return 1
  fi
}
# Static files the app references. No sw.js on purpose: a service worker inside the
# native shell would pin an old index.html across app updates.
STATIC_FILES="manifest.json icon-logm8-v2-192.png icon-logm8-v2-512.png icon-logm8-v2-180.png \
  favicon-32.png favicon-16.png logo-report.png logo-report.svg logbook-template.xlsx \
  version.json health.json privacy.html delete-account.html"
use_snapshot() {
  [ -f web-snapshot/app.html ] || { echo "ERROR: web-snapshot/app.html missing"; return 1; }
  rm -rf www && mkdir -p www/vendor
  cp web-snapshot/app.html www/index.html
  for f in $STATIC_FILES; do [ -f "web-snapshot/$f" ] && cp "web-snapshot/$f" "www/$f"; done
  echo "   web bundle taken from web-snapshot/ (app $(grep -o 'LOGM8_APP_CACHE_VERSION = [0-9]*' www/index.html), $(python3 -c "import json;print(json.load(open('www/version.json'))['appVersion'])" 2>/dev/null || echo '?'))"
}
WEB_SOURCE="${WEB_SOURCE:-auto}"
case "$WEB_SOURCE" in
  snapshot)
    use_snapshot || exit 1 ;;
  site)
    fetch_app || { echo "ERROR: could not fetch the LogM8 app from $SITE"; exit 1; }
    for f in $STATIC_FILES; do fetch "$f" "$f" || true; done ;;
  *)
    if fetch_app; then
      for f in $STATIC_FILES; do fetch "$f" "$f" || true; done
    else
      echo "   WARNING: live site unreachable from this runner (SiteGround anti-bot?) -> using web-snapshot/"
      use_snapshot || exit 1
    fi ;;
esac
grep -q "LOGM8_APP_CACHE_VERSION" www/index.html || { echo "ERROR: www/index.html is not the LogM8 app"; exit 1; }

echo "== 3/6 native tweaks"
# The app does `await import('@revenuecat/purchases-capacitor')` (a bare specifier). Bundle the
# plugin as a single ESM file and map the specifier to it with an import map.
npx esbuild node_modules/@revenuecat/purchases-capacitor/dist/esm/index.js \
  --bundle --format=esm --platform=browser --log-level=warning \
  --outfile=www/vendor/purchases-capacitor.js
# Native Google Sign-In: the web app's "Continue with Google" uses signInWithRedirect, which cannot
# work inside the Android WebView (it bounces to Chrome and back to https://localhost). Inside the
# app we call the native Firebase Authentication plugin instead and hand the Google ID token to the
# Firebase JS SDK (signInWithCredential). The bridge below is what `import('@capacitor-firebase/authentication')` resolves to.
npx esbuild vendor-src/firebase-authentication.js \
  --bundle --format=esm --platform=browser --log-level=warning \
  --outfile=www/vendor/firebase-authentication.js
# Owner home-screen widget: the web app hands the signed-in user's refresh token to native storage
# (Capacitor Preferences) so the widget can fetch dashboard totals in the background.
npx esbuild node_modules/@capacitor/preferences/dist/esm/index.js \
  --bundle --format=esm --platform=browser --log-level=warning \
  --outfile=www/vendor/preferences.js
RC_ANDROID_KEY="${RC_ANDROID_KEY:-}" python3 - <<'PY'
import os, re
p = 'www/index.html'
s = open(p, encoding='utf-8').read()
importmap = ('<script type="importmap">{"imports":{'
             '"@revenuecat/purchases-capacitor":"./vendor/purchases-capacitor.js",'
             '"@capacitor-firebase/authentication":"./vendor/firebase-authentication.js",'
             '"@capacitor/preferences":"./vendor/preferences.js"'
             '}}</script>')
if 'type="importmap"' not in s:
    s = re.sub(r'(<head[^>]*>)', lambda m: m.group(1) + '\n' + importmap, s, count=1)
    print('   import map injected')

# --- native Google Sign-In patch (no-op if the app already ships nativeGoogleSignIn) ---
if 'nativeGoogleSignIn' in s:
    print('   native Google Sign-In already present in app.html')
else:
    imp_pat = r"(getRedirectResult,\s*GoogleAuthProvider,)"
    s, n1 = re.subn(imp_pat, r"\1 signInWithCredential,", s, count=1)
    helper = (
        "// Native Google Sign-In (Android app only). Web keeps signInWithRedirect.\n"
        "async function nativeGoogleSignIn() {\n"
        "  const { FirebaseAuthentication } = await import('@capacitor-firebase/authentication');\n"
        "  const result = await FirebaseAuthentication.signInWithGoogle({ scopes: ['email', 'profile'] });\n"
        "  const idToken = result?.credential?.idToken;\n"
        "  if (!idToken) { const err = new Error('Google sign-in did not return a token'); err.code = 'auth/native-no-token'; throw err; }\n"
        "  const credential = GoogleAuthProvider.credential(idToken, result?.credential?.accessToken || undefined);\n"
        "  await signInWithCredential(auth, credential);\n"
        "}\n"
        "window.signInGoogle = async () => {"
    )
    s, n2 = re.subn(r"window\.signInGoogle\s*=\s*async\s*\(\)\s*=>\s*\{", helper, s, count=1)
    branch = (
        "await authPersistenceReady;\n"
        "    if (isNative()) {\n"
        "      try { await nativeGoogleSignIn(); }\n"
        "      catch (e) { if (!/cancel/i.test(String(e?.message || e?.code || ''))) showAuthError(friendlyError(e?.code || 'auth/native-google-failed')); }\n"
        "      return;\n"
        "    }\n"
        "    try { sessionStorage.setItem('logm8_google_redirect_pending', '1'); } catch (_err) {}\n"
        "    await signInWithRedirect(auth, googleProvider);"
    )
    branch_pat = (r"await authPersistenceReady;\s*"
                  r"try \{ sessionStorage\.setItem\('logm8_google_redirect_pending', '1'\); \} catch \(_err\) \{\}\s*"
                  r"await signInWithRedirect\(auth, googleProvider\);")
    s, n3 = re.subn(branch_pat, branch, s, count=1)
    if n1 == 1 and n2 == 1 and n3 == 1:
        print('   native Google Sign-In patch applied')
    else:
        raise SystemExit(f'ERROR: native Google Sign-In patch failed (import={n1} helper={n2} branch={n3}) - app.html changed?')

# --- owner widget auth bridge (no-op if already present) ---
if 'logm8_widget_auth' in s:
    print('   widget auth bridge already present')
else:
    bridge = (
        "// Owner home-screen widget (Android app only): keep the Firebase refresh token in native\n"
        "// storage so the widget can load dashboard totals in the background.\n"
        "if (isNative()) {\n"
        "  onAuthStateChanged(auth, async (widgetUser) => {\n"
        "    try {\n"
        "      const { Preferences } = await import('@capacitor/preferences');\n"
        "      if (widgetUser && widgetUser.refreshToken) {\n"
        "        await Preferences.set({ key: 'logm8_widget_auth', value: JSON.stringify({ uid: widgetUser.uid, email: widgetUser.email || '', refreshToken: widgetUser.refreshToken, savedAtMs: Date.now() }) });\n"
        "      } else {\n"
        "        await Preferences.remove({ key: 'logm8_widget_auth' });\n"
        "      }\n"
        "    } catch (e) { console.warn('widget auth bridge:', e); }\n"
        "  });\n"
        "}\n"
        "async function nativeGoogleSignIn() {"
    )
    s, n4 = re.subn(r"async function nativeGoogleSignIn\(\) \{", bridge, s, count=1)
    if n4 == 1:
        print('   widget auth bridge applied')
    else:
        raise SystemExit('ERROR: widget auth bridge patch failed')
# --- closed-testing tester allowlist (tester-hashes.txt) ---
# Testers get the app's demo/test tier (never trial-locked, Pro features) so they can test
# for months without paying. Only SHA-256 hashes of the tester emails ship in the build
# (hash-testers.sh turns the local, uncommitted tester-emails.txt into tester-hashes.txt).
hashes = []
if os.path.exists('tester-hashes.txt'):
    for line in open('tester-hashes.txt', encoding='utf-8'):
        h = line.split('#', 1)[0].strip().lower()
        if re.fullmatch(r'[0-9a-f]{64}', h) and h not in hashes:
            hashes.append(h)
if 'TESTER_EMAIL_HASHES' in s:
    print('   tester allowlist already present in app.html')
else:
    hash_list = ', '.join("'" + h + "'" for h in hashes)
    tester_code = (
        "// Closed-testing allowlist (Android build only): SHA-256 hashes of tester emails.\n"
        "// Matching users get the demo/test tier with Pro features and are never trial-locked.\n"
        "const TESTER_EMAIL_HASHES = new Set([" + hash_list + "]);\n"
        "let currentUserIsTester = false;\n"
        "async function refreshTesterFlag(user) {\n"
        "  currentUserIsTester = false;\n"
        "  try {\n"
        "    const email = String(user?.email || '').trim().toLowerCase();\n"
        "    if (!email || !TESTER_EMAIL_HASHES.size || !window.crypto?.subtle) return;\n"
        "    const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(email));\n"
        "    const hex = Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');\n"
        "    currentUserIsTester = TESTER_EMAIL_HASHES.has(hex);\n"
        "  } catch (e) { console.warn('tester allowlist check:', e); }\n"
        "}\n"
        "const DEMO_TIER_BY_EMAIL = {"
    )
    s, t1 = re.subn(r"const\s+DEMO_TIER_BY_EMAIL\s*=\s*\{", lambda m: tester_code, s, count=1)
    s, t2 = re.subn(r"(function getDemoTierOverride\(\) \{)", r"\1\n  if (currentUserIsTester) return 'test';", s, count=1)
    s, t3 = re.subn(r"(function getDemoAccessOverride\(\) \{)", r"\1\n  if (currentUserIsTester) return 'pro';", s, count=1)
    s, t4 = re.subn(r"(resetAuthButtons\(\);\s*currentUser = user;)", r"\1\n    await refreshTesterFlag(user);", s, count=1)
    if t1 == 1 and t2 == 1 and t3 == 1 and t4 == 1:
        print(f'   tester allowlist applied: {len(hashes)} email hashes')
    else:
        raise SystemExit(f'ERROR: tester allowlist patch failed (const={t1} tier={t2} access={t3} hook={t4}) - app.html changed?')

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
# Firebase Android config (Google Sign-In). Not a secret: the same values ship inside the APK.
if [ -n "${GOOGLE_SERVICES_JSON_B64:-}" ]; then
  echo "$GOOGLE_SERVICES_JSON_B64" | tr -d '\n\r ' | base64 -d > android/app/google-services.json
elif [ -f google-services.json ]; then
  cp -f google-services.json android/app/google-services.json
fi
if [ -f android/app/google-services.json ]; then
  python3 -c "import json;d=json.load(open('android/app/google-services.json'));print('   google-services.json: project', d['project_info']['project_id'], '| apps:', [c['client_info']['android_client_info']['package_name'] for c in d['client']])"
else
  echo "   WARNING: no google-services.json -> native Google Sign-In will fail at runtime"
fi
# @capacitor-firebase/authentication only links the Google Sign-In SDK when this flag is set
sed -i 's/^ext {/ext {\n    rgcfaIncludeGoogle = true/' android/variables.gradle
grep -q rgcfaIncludeGoogle android/variables.gradle || { echo "ERROR: could not set rgcfaIncludeGoogle"; exit 1; }
sed -e "s/__VERSION_CODE__/${VERSION_CODE}/" -e "s/__VERSION_NAME__/${VERSION_NAME}/" \
    overlay-app-build.gradle > android/app/build.gradle
# Native extras (owner home-screen widget): Java sources + resources
cp -R overlay-android/java/. android/app/src/main/java/
cp -R overlay-android/res/. android/app/src/main/res/
echo "   native overlay: $(find overlay-android -type f | wc -l) files (widget)"
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
