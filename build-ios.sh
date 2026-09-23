#!/usr/bin/env bash
# LogM8 iOS build
# Wraps the same LogM8 web bundle as the Android build (build.sh steps 1-3) in a Capacitor 8 iOS
# shell, archives it with Xcode and uploads it to App Store Connect (TestFlight).
# Runs on macOS (GitHub Actions macos runner). SKIP_XCODE=1 lets the project generation part
# run anywhere for validation.
#
# Inputs (environment variables):
#   VERSION_NAME   CFBundleShortVersionString shown in the App Store      (default 1.5.30)
#   BUILD_NUMBER   CFBundleVersion, integer, must increase every upload     (default 1)
#   WEB_SOURCE     snapshot | site | auto                                    (see build.sh)
#   ASC_KEY_PATH   path to the App Store Connect API key (AuthKey_<id>.p8, Admin role)
#   ASC_KEY_ID     key id            (default LV2RZTJTC2)
#   ASC_ISSUER_ID  issuer id         (default 943eea3e-92c5-46e4-b6db-432476be023e)
#                  -> Xcode automatic cloud signing (no certificates/profiles to manage) + upload
#   RC_IOS_KEY     RevenueCat Apple public API key (appl_...) -> enables native subscriptions
#   SKIP_XCODE=1   stop after the Xcode project is generated
#
# Output: build/App.xcarchive, build/export/ (+ the build appears in TestFlight after processing)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

VERSION_NAME="${VERSION_NAME:-1.5.30}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
TEAM_ID="M8P36WDDRQ"
BUNDLE_ID="au.com.logm8.app"
ASC_KEY_ID="${ASC_KEY_ID:-LV2RZTJTC2}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-943eea3e-92c5-46e4-b6db-432476be023e}"

echo "== LogM8 iOS build: version=$VERSION_NAME build=$BUILD_NUMBER bundle=$BUNDLE_ID"

echo "== 1/6 web bundle (build.sh steps 1-3: fetch/snapshot + native patches)"
WEB_ONLY=1 bash build.sh
# The iOS platform package is not part of the Android lockfile; add it for this build only.
npm install --no-save --no-audit --no-fund @capacitor/ios@"$(node -p "require('@capacitor/cli/package.json').version")"

echo "== 2/6 iOS-specific web tweaks"
RC_IOS_KEY="${RC_IOS_KEY:-}" python3 - <<'PY'
import os, re
p = 'www/index.html'
s = open(p, encoding='utf-8').read()

# --- store wording: this bundle only ever runs inside the iOS app ---
# (build.sh's esbuild pass may have turned single quotes into double quotes - handle both)
n_words = 0
for a, b in [
    ("Manage billing in Google Play", "Manage billing in the App Store"),
    ("Subscribe via Google Play", "Subscribe via the App Store"),
    ("Opening Play Store...", "Opening the App Store..."),
    ("Subscription managed by Google Play - Cancel anytime", "Subscription managed by the App Store - Cancel anytime"),
]:
    for q in ("'", '"'):
        n_words += s.count(q + a + q)
        s = s.replace(q + a + q, q + b + q)
print('   App Store wording applied (%d strings)' % n_words)

# --- Sign in with Apple (App Store rule 4.8: an app that offers Google sign-in must offer Apple sign-in) ---
if 'signInApple' in s:
    print('   Sign in with Apple already present')
else:
    s, n_imp = re.subn(r"(getRedirectResult,\s*GoogleAuthProvider,)", r"\1 OAuthProvider,", s, count=1)
    css = (".apple-btn{width:100%;margin-top:10px;padding:13px;background:#000;color:#fff;border:0.5px solid #444;"
           "border-radius:12px;font-size:14px;font-weight:500;cursor:pointer;font-family:inherit;display:flex;"
           "align-items:center;justify-content:center;gap:10px;transition:background .2s}"
           ".apple-btn:hover{background:#111}.apple-btn svg{width:18px;height:18px;flex-shrink:0;fill:#fff}\n")
    s, n_css = re.subn(r"(\.google-btn svg\{[^}]*\}\n)", lambda m: m.group(1) + css, s, count=1)
    button = (
        '    <button class="apple-btn" onclick="signInApple()" id="apple-signin-btn" aria-label="Continue with Apple">\n'
        '      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12.152 6.896c-.948 0-2.415-1.078-3.96-1.04-2.04.027-3.91 1.183-4.961 3.014-2.117 3.675-.546 9.103 1.519 12.09 1.013 1.454 2.208 3.09 3.792 3.039 1.52-.065 2.09-.987 3.935-.987 1.831 0 2.35.987 3.96.948 1.637-.026 2.676-1.48 3.676-2.948 1.156-1.688 1.636-3.325 1.662-3.415-.039-.013-3.182-1.221-3.22-4.857-.026-3.04 2.48-4.494 2.597-4.559-1.429-2.09-3.623-2.324-4.39-2.376-2-.156-3.675 1.09-4.61 1.09zM15.53 3.83c.843-1.012 1.4-2.427 1.245-3.83-1.207.052-2.662.805-3.532 1.818-.78.896-1.454 2.338-1.273 3.714 1.338.104 2.715-.688 3.559-1.701"/></svg>\n'
        '      Continue with Apple\n'
        '    </button>\n'
    )
    s, n_btn = re.subn(r"(      Continue with Google\n    </button>\n)", lambda m: m.group(1) + button, s, count=1)
    handler = (
        "// Sign in with Apple (iOS app only): native sheet -> Apple ID token -> Firebase signInWithCredential.\n"
        "window.signInApple = async () => {\n"
        "  try {\n"
        "    clearAuthMessages();\n"
        "    await authPersistenceReady;\n"
        "    const { FirebaseAuthentication } = await import('@capacitor-firebase/authentication');\n"
        "    const result = await FirebaseAuthentication.signInWithApple({ skipNativeAuth: true, scopes: ['email', 'name'] });\n"
        "    const idToken = result?.credential?.idToken;\n"
        "    const rawNonce = result?.credential?.nonce;\n"
        "    if (!idToken) { const err = new Error('Apple sign-in did not return a token'); err.code = 'auth/native-no-token'; throw err; }\n"
        "    const provider = new OAuthProvider('apple.com');\n"
        "    const credential = provider.credential({ idToken, rawNonce });\n"
        "    const signedIn = await signInWithCredential(auth, credential);\n"
        "    // Apple only shares the name on the very first sign-in: keep it on the Firebase profile.\n"
        "    const appleName = result?.user?.displayName || [result?.additionalUserInfo?.profile?.givenName, result?.additionalUserInfo?.profile?.familyName].filter(Boolean).join(' ');\n"
        "    if (signedIn?.user && !signedIn.user.displayName && appleName) { try { await updateProfile(signedIn.user, { displayName: appleName }); } catch (_e) {} }\n"
        "  } catch (e) {\n"
        "    const msg = String(e?.message || e?.code || '');\n"
        "    if (/cancel|1001/i.test(msg)) return;\n"
        "    if (e?.code === 'auth/network-request-failed') { showAuthRepairError('LogM8 could not reach login services. Your connection may be offline or the app cache may be stale.'); return; }\n"
        "    showAuthError(friendlyError(e?.code || 'auth/native-apple-failed'));\n"
        "  }\n"
        "};\n\n"
        "window.signInGoogle = async () => {"
    )
    s, n_h = re.subn(r"window\.signInGoogle\s*=\s*async\s*\(\)\s*=>\s*\{", handler, s, count=1)
    if n_imp == 1 and n_css == 1 and n_btn == 1 and n_h == 1:
        print('   Sign in with Apple added (button + handler)')
    else:
        raise SystemExit(f'ERROR: Sign in with Apple patch failed (import={n_imp} css={n_css} button={n_btn} handler={n_h}) - app.html changed?')

# --- RevenueCat Apple key (the constant name is historical; it is the key used on the running platform) ---
key = os.environ.get('RC_IOS_KEY', '').strip()
pat = r"(const\s+RC_ANDROID_KEY\s*=\s*)['\"]YOUR_REVENUECAT_ANDROID_KEY['\"]"
if key.startswith('appl_'):
    s, n = re.subn(pat, lambda m: m.group(1) + '"' + key + '"', s, count=1)
    print('   RevenueCat Apple key injected' if n else '   WARNING: RevenueCat key placeholder not found')
else:
    print('   RevenueCat Apple key not provided -> native purchases disabled in this build')
open(p, 'w', encoding='utf-8').write(s)
PY
cp www/index.html www/app.html
# Firebase iOS config. Not a secret: the same values ship inside the app. It lives in the web folder
# (App.app/public/) because AppDelegate loads it from there - no Xcode project surgery needed.
cp ios-overlay/GoogleService-Info.plist www/GoogleService-Info.plist

echo "== 3/6 Capacitor iOS project"
rm -rf ios
npx cap add ios
# Capacitor 8 generates a Swift Package Manager project (ios/App/CapApp-SPM). The Firebase
# Authentication plugin pulls the Google Sign-In SDK through its "Google" package trait (enabled by
# default, selected explicitly in capacitor.config.json together with the Facebook trait left out).
grep -q "GoogleSignIn\|CapacitorFirebaseAuthentication" ios/App/CapApp-SPM/Package.swift || { echo "ERROR: Firebase Authentication plugin missing from Package.swift"; exit 1; }
# AppDelegate: configure Firebase from public/GoogleService-Info.plist before any plugin loads
cp -f ios-overlay/AppDelegate.swift ios/App/App/AppDelegate.swift
cp -f ios-overlay/App.entitlements ios/App/App/App.entitlements
# Shared scheme so `xcodebuild -scheme App` works on a fresh runner (the template ships none)
python3 - <<'PY'
import re, os
pbx = open('ios/App/App.xcodeproj/project.pbxproj', encoding='utf-8').read()
m = re.search(r'([0-9A-F]{24}) /\* App \*/ = \{\s*isa = PBXNativeTarget;', pbx)
assert m, 'App target not found in project.pbxproj'
scheme = open('ios-overlay/App.xcscheme', encoding='utf-8').read().replace('__TARGET_ID__', m.group(1))
os.makedirs('ios/App/App.xcodeproj/xcshareddata/xcschemes', exist_ok=True)
open('ios/App/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme', 'w', encoding='utf-8').write(scheme)
print('   shared scheme App written (target %s)' % m.group(1))
PY
# Info.plist: name, versions, permissions texts, Google Sign-In URL scheme, export compliance
VERSION_NAME="$VERSION_NAME" BUILD_NUMBER="$BUILD_NUMBER" python3 - <<'PY'
import os, plistlib
gs = plistlib.load(open('ios-overlay/GoogleService-Info.plist', 'rb'))
p = 'ios/App/App/Info.plist'
d = plistlib.load(open(p, 'rb'))
d['CFBundleDisplayName'] = 'LogM8'
d['CFBundleShortVersionString'] = os.environ['VERSION_NAME']
d['CFBundleVersion'] = os.environ['BUILD_NUMBER']
d['NSLocationWhenInUseUsageDescription'] = 'LogM8 uses your location to record the distance and route of your trips in your vehicle logbook.'
d['NSLocationAlwaysAndWhenInUseUsageDescription'] = d['NSLocationWhenInUseUsageDescription']
d['NSCameraUsageDescription'] = 'LogM8 uses the camera to photograph receipts and odometer readings.'
d['NSPhotoLibraryUsageDescription'] = 'LogM8 lets you attach receipt photos from your photo library.'
d['ITSAppUsesNonExemptEncryption'] = False
d['CFBundleURLTypes'] = [{'CFBundleTypeRole': 'Editor', 'CFBundleURLName': 'google-sign-in',
                          'CFBundleURLSchemes': [gs['REVERSED_CLIENT_ID']]}]
d['UISupportedInterfaceOrientations'] = ['UIInterfaceOrientationPortrait']
d.pop('UIRequiredDeviceCapabilities', None)
plistlib.dump(d, open(p, 'wb'))
print('   Info.plist updated (display name, %s (%s), permissions, URL scheme)' % (d['CFBundleShortVersionString'], d['CFBundleVersion']))
PY
# Xcode project: team, entitlements, iPhone only. The template keeps these keys only in the App target.
PBX=ios/App/App.xcodeproj/project.pbxproj
python3 - "$PBX" "$TEAM_ID" "$BUNDLE_ID" <<'PY'
import re, sys
p, team, bundle = sys.argv[1:4]
s = open(p, encoding='utf-8').read()
n_id = len(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = ' + re.escape(bundle) + ';', s))
if n_id == 0:
    s, n_id = re.subn(r'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;', 'PRODUCT_BUNDLE_IDENTIFIER = %s;' % bundle, s)
s, n_ent = re.subn(r'(\n(\s*)PRODUCT_BUNDLE_IDENTIFIER = )',
                   lambda m: '\n%sCODE_SIGN_ENTITLEMENTS = App/App.entitlements;\n%sDEVELOPMENT_TEAM = %s;%s' % (m.group(2), m.group(2), team, m.group(1)), s)
s, n_fam = re.subn(r'TARGETED_DEVICE_FAMILY = "1,2";', 'TARGETED_DEVICE_FAMILY = 1;', s)
open(p, 'w', encoding='utf-8').write(s)
print('   project.pbxproj: bundle id x%d, entitlements+team x%d, iPhone-only x%d' % (n_id, n_ent, n_fam))
assert n_id >= 2 and n_ent >= 2, 'unexpected project.pbxproj layout'
PY
npx cap sync ios

echo "== 4/6 app icon and splash"
npx @capacitor/assets generate --ios --assetPath resources \
  --iconBackgroundColor '#0a0a0a' --iconBackgroundColorDark '#0a0a0a' \
  --splashBackgroundColor '#0a0a0a' --splashBackgroundColorDark '#0a0a0a'

if [ "${SKIP_XCODE:-}" = "1" ]; then echo "== SKIP_XCODE=1, stopping before xcodebuild"; exit 0; fi

mkdir -p build
AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  echo "   signing: Xcode automatic (cloud) signing with App Store Connect API key $ASC_KEY_ID"
  # Automatic signing needs a development profile for the archive step, which Apple only issues
  # when the team has at least one registered device (the export step re-signs for the App Store).
  ASC_KEY_PATH="$ASC_KEY_PATH" ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" node ios-overlay/asc-ensure-device.mjs
else
  echo "   signing: no API key -> archive will fail unless certificates are installed"
fi

echo "== 5/6 xcodebuild archive"
xcodebuild -version
set +e
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ROOT/build/App.xcarchive" archive \
  -skipPackagePluginValidation -skipMacroValidation \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic "${AUTH[@]}" > build/archive.log 2>&1
rc=$?
set -e
grep -E "error:|warning: .*(sign|provision)|\*\* ARCHIVE" build/archive.log | head -40 || true
if [ $rc -ne 0 ] || [ ! -d build/App.xcarchive ]; then
  echo "ERROR: archive failed (exit $rc). Last lines:"; tail -120 build/archive.log; exit 1
fi

echo "== 6/6 export + upload to App Store Connect (TestFlight)"
sed "s/__TEAM_ID__/$TEAM_ID/" ios-overlay/ExportOptions.plist > build/ExportOptions.plist
set +e
xcodebuild -exportArchive -archivePath "$ROOT/build/App.xcarchive" \
  -exportOptionsPlist build/ExportOptions.plist -exportPath "$ROOT/build/export" "${AUTH[@]}" > build/export.log 2>&1
rc=$?
set -e
grep -E "error:|Upload|Exported|EXPORT" build/export.log | head -40 || true
if [ $rc -ne 0 ]; then echo "ERROR: export/upload failed (exit $rc). Last lines:"; tail -120 build/export.log; exit 1; fi
echo "== DONE: $VERSION_NAME ($BUILD_NUMBER) uploaded - it shows up in App Store Connect > TestFlight after processing"
ls -la build/export 2>/dev/null || true
