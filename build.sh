#!/usr/bin/env bash
# LogM8 Android build
# Wraps the live LogM8 web app (https://www.logm8.com.au/app.html) in a Capacitor 8 shell
# and builds a signed Android App Bundle (AAB) ready for the Play Console.
#
# Inputs (environment variables):
#   VERSION_NAME       versionName shown to users            (default 1.5.30)
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
VERSION_NAME="${VERSION_NAME:-1.5.30}"
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
# Default = snapshot: web-snapshot/app.html carries app changes that are not on the live site yet
# (trip guard 1.5.30). Use WEB_SOURCE=site only after the same app.html has been deployed there.
WEB_SOURCE="${WEB_SOURCE:-snapshot}"
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
  --bundle --format=esm --platform=browser --target=chrome70 --log-level=warning \
  --outfile=www/vendor/purchases-capacitor.js
# Native Google Sign-In: the web app's "Continue with Google" uses signInWithRedirect, which cannot
# work inside the Android WebView (it bounces to Chrome and back to https://localhost). Inside the
# app we call the native Firebase Authentication plugin instead and hand the Google ID token to the
# Firebase JS SDK (signInWithCredential). The bridge below is what `import('@capacitor-firebase/authentication')` resolves to.
npx esbuild vendor-src/firebase-authentication.js \
  --bundle --format=esm --platform=browser --target=chrome70 --log-level=warning \
  --outfile=www/vendor/firebase-authentication.js
# Owner home-screen widget: the web app hands the signed-in user's refresh token to native storage
# (Capacitor Preferences) so the widget can fetch dashboard totals in the background.
npx esbuild node_modules/@capacitor/preferences/dist/esm/index.js \
  --bundle --format=esm --platform=browser --target=chrome70 --log-level=warning \
  --outfile=www/vendor/preferences.js
# Trip reminders: local notifications scheduled by the OS ("trip still running" 1h/2h/4h/8h/12h
# after Start), so they fire even when the app is closed. The web app imports the plugin lazily.
npx esbuild node_modules/@capacitor/local-notifications/dist/esm/index.js \
  --bundle --format=esm --platform=browser --target=chrome70 --log-level=warning \
  --outfile=www/vendor/local-notifications.js
RC_ANDROID_KEY="${RC_ANDROID_KEY:-}" python3 - <<'PY'
import os, re
p = 'www/index.html'
s = open(p, encoding='utf-8').read()
importmap = ('<script type="importmap">{"imports":{'
             '"@revenuecat/purchases-capacitor":"./vendor/purchases-capacitor.js",'
             '"@capacitor-firebase/authentication":"./vendor/firebase-authentication.js",'
             '"@capacitor/preferences":"./vendor/preferences.js",'
             '"@capacitor/local-notifications":"./vendor/local-notifications.js"'
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
        "      // Only the owner account keeps a token for the widget; everyone else is cleared.\n"
        "      if (widgetUser && widgetUser.refreshToken && typeof isOwnerAdmin === 'function' && isOwnerAdmin(widgetUser.email)) {\n"
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
# --- closed-testing testers: granted SERVER-SIDE now (functions TESTER_EMAIL_HASHES ->
# subscription plan "tester_forever"), so no email hashes ship in the app or this public repo.

# --- avatar fallback: Google profile photos can fail to load inside the WebView (broken "avatar"
# alt text). Send no referrer and fall back to the initial letter on error. Idempotent.
if 'referrerpolicy="no-referrer"' not in s:
    s, n_av = re.subn(r'<img src="\$\{photo\}" alt="avatar"/>',
                      '<img src="${photo}" alt="avatar" referrerpolicy="no-referrer" onerror="this.parentNode.textContent=\'${initial}\'"/>', s)
    print(f'   avatar fallback applied ({n_av} places)')

# --- native purchase UI (both stores): prices come from the store (RevenueCat offerings), the modal
# sells the Basic tier only (there are no native Pro products), no Stripe wording, and the legal line
# carries Terms/Privacy links (App Store rule 3.1.2). Also fixes the package lookup: on Google Play
# RevenueCat product identifiers are "productId:basePlanId", so the exact match never hit and the
# code silently fell back to the FIRST package whatever plan the user picked. Idempotent.
if 'NATIVE_STORE_PRICES' in s:
    print('   native purchase UI patch already present')
else:
    consts = (
        "const RC_PRODUCT_ANNUAL  = 'logm8_basic_annual';\n"
        "// Native purchase UI: the store's own prices, Basic tier only (no native Pro products), no Stripe wording.\n"
        "const NATIVE_STORE_NAME = 'Google Play';\n"
        "const NATIVE_TERMS_URL = '';\n"
        "const NATIVE_PRIVACY_URL = 'https://www.logm8.com.au/privacy.html';\n"
        "const NATIVE_STORE_PRICES = {};\n"
        "function nativeLegalHtml() {\n"
        "  const links = [];\n"
        "  if (NATIVE_TERMS_URL) links.push('<a href=\"' + NATIVE_TERMS_URL + '\" target=\"_blank\" rel=\"noopener\">Terms of Use</a>');\n"
        "  links.push('<a href=\"' + NATIVE_PRIVACY_URL + '\" target=\"_blank\" rel=\"noopener\">Privacy Policy</a>');\n"
        "  return 'Subscription managed by ' + NATIVE_STORE_NAME + ' - Cancel anytime \\u00b7 ' + links.join(' \\u00b7 ');\n"
        "}\n"
        "function applyNativeStorePrices(offerings) {\n"
        "  const pkgs = offerings?.current?.availablePackages || [];\n"
        "  for (const pkg of pkgs) {\n"
        "    const id = String(pkg?.product?.identifier || '').split(':')[0];\n"
        "    const price = pkg?.product?.priceString || '';\n"
        "    if (!price) continue;\n"
        "    if (id === RC_PRODUCT_WEEKLY) NATIVE_STORE_PRICES.weekly = price;\n"
        "    else if (id === RC_PRODUCT_MONTHLY) NATIVE_STORE_PRICES.monthly = price;\n"
        "    else if (id === RC_PRODUCT_ANNUAL) NATIVE_STORE_PRICES.annual = price;\n"
        "  }\n"
        "}\n"
    )
    s, p1 = re.subn(r"const RC_PRODUCT_ANNUAL\s*=\s*'logm8_basic_annual';\n", lambda m: consts, s, count=1)
    price_pat = (r"  document\.getElementById\('price-weekly'\)\.textContent = PLAN_DISPLAY\[selectedTier\]\.weekly\.price;\n"
                 r"  document\.getElementById\('price-monthly'\)\.textContent = PLAN_DISPLAY\[selectedTier\]\.monthly\.price;\n"
                 r"  document\.getElementById\('price-annual'\)\.textContent = PLAN_DISPLAY\[selectedTier\]\.annual\.price;\n")
    price_new = (
        "  const priceOf = (k, unit) => (isNative() && NATIVE_STORE_PRICES[k]) ? NATIVE_STORE_PRICES[k] + ' / ' + unit : PLAN_DISPLAY[selectedTier][k].price;\n"
        "  document.getElementById('price-weekly').textContent = priceOf('weekly', 'wk');\n"
        "  document.getElementById('price-monthly').textContent = priceOf('monthly', 'mo');\n"
        "  document.getElementById('price-annual').textContent = priceOf('annual', 'yr');\n"
    )
    s, p2 = re.subn(price_pat, lambda m: price_new, s, count=1)
    s, p3 = re.subn(r"  if \(legal\) legal\.textContent = display\.legal;\n",
                    "  if (legal) { if (isNative()) legal.innerHTML = nativeLegalHtml(); else legal.textContent = display.legal; }\n", s, count=1)
    s, p4 = re.subn(r"legal\.textContent = 'Subscription managed by Google Play - Cancel anytime';",
                    "legal.innerHTML = nativeLegalHtml();", s, count=1)
    native_ui = (
        "    applyNativeStorePrices(offerings);\n"
        "    selectedTier = 'basic';\n"
        "    document.querySelector('.tier-toggle')?.style.setProperty('display', 'none');\n"
        "    document.getElementById('plan-highlight')?.style.setProperty('display', 'none');\n"
        "    document.querySelector('.trial-strip')?.style.setProperty('display', 'none');\n"
        "    syncSelectedPlanUI(selectedPlan, 'basic');\n"
    )
    s, p5 = re.subn(r"(if \(!offerings\.current\) \{ showToast\('No plans available'\); return; \}\n)",
                    lambda m: m.group(1) + native_ui, s, count=1)
    s, p6 = re.subn(r"p\.product\?\.identifier === productId\n\s*\) \|\| offerings\.current\?\.availablePackages\?\.\[0\];",
                    "String(p.product?.identifier || '').split(':')[0] === productId\n    );", s, count=1)
    s, p7 = re.subn(r"(\.upgrade-legal\{[^}]*\})", r"\1.upgrade-legal a{color:inherit;text-decoration:underline}", s, count=1)
    if p1 == p2 == p3 == p4 == p5 == p6 == p7 == 1:
        print('   native purchase UI patch applied (store prices, Basic only, Terms/Privacy links, package lookup fix)')
    else:
        raise SystemExit(f'ERROR: native purchase UI patch failed (consts={p1} prices={p2} legal={p3} legal2={p4} modal={p5} lookup={p6} css={p7}) - app.html changed?')

# --- RevenueCat identity: purchases must belong to the Firebase uid, otherwise the backend
# (refreshMySubscription / revenueCatWebhook) can never see a Google Play / App Store purchase. Idempotent.
if 'async function rcIdentify()' not in s:
    ident = (
        "// RevenueCat app_user_id = Firebase uid, so the server can verify store purchases.\n"
        "async function rcIdentify() {\n"
        "  if (!rcPurchases || !currentUser?.uid) return;\n"
        "  try { await rcPurchases.logIn({ appUserID: currentUser.uid }); }\n"
        "  catch (e) { console.warn('RevenueCat logIn failed:', e); }\n"
        "}\n"
    )
    s, r1 = re.subn(r"(let rcPurchases = null;[^\n]*\n)", lambda m: m.group(1) + ident, s, count=1)
    s, r2 = re.subn(r"(console\.log\('RevenueCat configured'\);)", r"\1\n    rcIdentify().catch(() => null);", s, count=1)
    s, r3 = re.subn(r"(\n(\s*)const \{ customerInfo \} = await rcPurchases\.purchasePackage\()", lambda m: "\n" + m.group(2) + "await rcIdentify();" + m.group(1), s, count=1)
    s, r4 = re.subn(r"(\n(\s*)const \{ customerInfo \} = await rcPurchases\.restorePurchases\(\))", lambda m: "\n" + m.group(2) + "await rcIdentify();" + m.group(1), s, count=1)
    s, r5 = re.subn(r"(resetAuthButtons\(\);\s*currentUser = user;)", r"\1\n    rcIdentify().catch(() => null);", s, count=1)
    if r1 == r2 == r3 == r4 == r5 == 1:
        print('   RevenueCat identity patch applied')
    else:
        raise SystemExit(f'ERROR: RevenueCat identity patch failed (decl={r1} cfg={r2} buy={r3} restore={r4} auth={r5}) - app.html changed?')

key = os.environ.get('RC_ANDROID_KEY', '').strip()
pat = r"(const\s+RC_ANDROID_KEY\s*=\s*)'YOUR_REVENUECAT_ANDROID_KEY'"
if key.startswith('goog_'):
    s, n = re.subn(pat, lambda m: m.group(1) + "'" + key + "'", s, count=1)
    print('   RevenueCat key injected' if n else '   WARNING: RC_ANDROID_KEY placeholder not found')
else:
    print('   RevenueCat key not provided -> native purchases disabled in this build')
open(p, 'w', encoding='utf-8').write(s)
PY
# Older Android System WebViews (e.g. Huawei/EMUI phones that never updated it) choke on modern
# syntax: optional chaining needs Chrome 80+, import maps Chrome 89+. A SyntaxError there leaves
# the app stuck on the loading screen. Down-level the inline app module to Chrome 70 and point the
# dynamic plugin imports at the bundled vendor files directly (no import map needed).
node - <<'JS'
const fs = require('fs');
const { transformSync } = require('esbuild');
const p = 'www/index.html';
let s = fs.readFileSync(p, 'utf8');
const re = /<script type="module">([\s\S]*?)<\/script>/;
const m = s.match(re);
if (!m) throw new Error('inline module script not found in index.html');
const js = m[1]
  .replace(/import\('@revenuecat\/purchases-capacitor'\)/g, "import('./vendor/purchases-capacitor.js')")
  .replace(/import\('@capacitor-firebase\/authentication'\)/g, "import('./vendor/firebase-authentication.js')")
  .replace(/import\('@capacitor\/preferences'\)/g, "import('./vendor/preferences.js')")
  .replace(/import\('@capacitor\/local-notifications'\)/g, "import('./vendor/local-notifications.js')");
const polyfill = "if (!Promise.allSettled) { Promise.allSettled = function (ps) { return Promise.all(Array.from(ps, function (p) { return Promise.resolve(p).then(function (value) { return { status: 'fulfilled', value: value }; }, function (reason) { return { status: 'rejected', reason: reason }; }); })); }; }\n";
const out = transformSync(js, { target: 'chrome70', format: 'esm', loader: 'js', legalComments: 'none' }).code;
s = s.replace(re, () => '<script type="module">\n' + polyfill + out + '</script>');
fs.writeFileSync(p, s);
console.log('   app module down-levelled for old WebViews (chrome70): ' + js.length + ' -> ' + out.length + ' chars');
JS
cp www/index.html www/app.html   # the app links to /app.html in a few places
echo "   web bundle: $(du -sh www | cut -f1)"
# build-ios.sh reuses steps 1-3 (same web bundle + patches) and then does the iOS-specific work.
if [ "${WEB_ONLY:-}" = "1" ]; then echo "== WEB_ONLY=1, web bundle ready in www/ (no Android project)"; exit 0; fi

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
