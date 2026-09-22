#!/usr/bin/env python3
"""Trip-guard patch for app.html (LogM8 1.5.30):
- forgotten trips: auto-stop after 12h, discard drafts older than 48h on restore,
  in-app reminder every 2h (was 10h), Discard button on the finished-trip card
- Android app: native local notifications (fire even with the app closed) at 1/2/4/8/12h
- version bump 1.5.29 -> 1.5.30, cache 93 -> 94
Idempotent: exits 0 without changes when the patch is already applied.
"""
import re, sys

p = sys.argv[1] if len(sys.argv) > 1 else 'web-snapshot/app.html'
s = open(p, encoding='utf-8').read()
if 'ACTIVE_TRIP_AUTO_STOP_MS' in s:
    print('trip guard already applied to', p)
    sys.exit(0)

def sub1(pattern, repl, flags=0, label=''):
    global s
    s, n = re.subn(pattern, repl, s, count=1, flags=flags)
    if n != 1:
        raise SystemExit(f'ERROR: anchor not found for {label or pattern[:60]}')
    print('  ok:', label or pattern[:60])

# --- version bump ---
sub1(r"window\.LOGM8_APP_CACHE_VERSION = 93;", "window.LOGM8_APP_CACHE_VERSION = 94;", label='cache version (head)')
sub1(r"const APP_VERSION = '1\.5\.29';", "const APP_VERSION = '1.5.30';", label='APP_VERSION')
sub1(r"const APP_CACHE_VERSION = '93';", "const APP_CACHE_VERSION = '94';", label='APP_CACHE_VERSION')

# --- constants ---
sub1(r"const ACTIVE_TRIP_REMINDER_MS = 10 \* 60 \* 60 \* 1000;",
     "const ACTIVE_TRIP_REMINDER_MS = 2 * 60 * 60 * 1000;      // in-app 'still running' reminder\n"
     "const ACTIVE_TRIP_AUTO_STOP_MS = 12 * 60 * 60 * 1000;    // a trip running this long is stopped automatically\n"
     "const ACTIVE_TRIP_STALE_MS = 48 * 60 * 60 * 1000;        // an unsaved draft older than this is discarded on restore\n"
     "const TRIP_NOTIFICATION_HOURS = [1, 2, 4, 8, 12];         // native reminders (Android app) after trip start\n"
     "const TRIP_NOTIFICATION_ID_BASE = 8100;",
     label='constants')

# --- Discard button on the finished-trip card ---
sub1(r'(<span id="save-trip-label">Save trip</span>\s*</button>)',
     r'\1\n          <button class="action-btn" id="discard-trip-btn" onclick="discardTrip()" style="margin-top:10px;background:transparent;border:1px solid var(--b1);color:var(--muted)">\n'
     r'            <svg viewBox="0 0 24 24"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/></svg><span>Discard trip</span>\n'
     r'          </button>',
     label='discard button')

# --- helpers: native reminders, auto-stop, discard ---
helpers = r'''
// Native reminders (Android app only): scheduled by the OS, so they fire even when LogM8 is closed.
async function getLocalNotificationsPlugin() {
  if (!isNative()) return null;
  try {
    const mod = await import('@capacitor/local-notifications');
    return mod.LocalNotifications || null;
  } catch (e) {
    console.warn('local notifications unavailable:', e);
    return null;
  }
}

function tripNotificationIds() {
  return TRIP_NOTIFICATION_HOURS.map((_, i) => ({ id: TRIP_NOTIFICATION_ID_BASE + i }));
}

async function scheduleTripNotifications(startedAtMs) {
  const plugin = await getLocalNotificationsPlugin();
  if (!plugin) return;
  try {
    let perm = await plugin.checkPermissions();
    if (perm.display !== 'granted') perm = await plugin.requestPermissions();
    if (perm.display !== 'granted') return;
    await plugin.cancel({ notifications: tripNotificationIds() });
    const nowMs = Date.now();
    const notifications = TRIP_NOTIFICATION_HOURS
      .map((hours, i) => ({
        id: TRIP_NOTIFICATION_ID_BASE + i,
        title: 'LogM8 trip still running',
        body: 'Your trip has been running for ' + hours + 'h. Open LogM8 and tap Stop when you arrive.',
        schedule: { at: new Date(startedAtMs + hours * 60 * 60 * 1000), allowWhileIdle: true }
      }))
      .filter(n => n.schedule.at.getTime() > nowMs + 30 * 1000);
    if (notifications.length) await plugin.schedule({ notifications });
  } catch (e) {
    console.warn('trip notifications:', e);
  }
}

async function cancelTripNotifications() {
  const plugin = await getLocalNotificationsPlugin();
  if (!plugin) return;
  try { await plugin.cancel({ notifications: tripNotificationIds() }); } catch (_) {}
}

// A trip nobody stopped: freeze it at the 12h mark instead of counting for days.
function autoStopActiveTrip() {
  if (!running) return;
  running = false;
  stopActiveTripTimers({ keepClock: true });
  stopGPS();
  secs = Math.min(secs, Math.floor(ACTIVE_TRIP_AUTO_STOP_MS / 1000));
  manualTripEndKm = getGpsEstimatedEndKm();
  showStoppedTripUI();
  saveActiveTripDraft('stopped');
  cancelTripNotifications();
  showToast('Trip stopped automatically after 12 hours. Review it, then Save or Discard.', 7000);
}

window.discardTrip = () => {
  if (!activeTripStartedAtMs && !getActiveTripDraft()) { resetTripUI(); return; }
  if (!confirm('Discard this trip? It will not be saved.')) return;
  clearActiveTripDraft();
  resetTripUI();
  cancelTripNotifications();
  showToast('Trip discarded');
};

function startActiveTripTimers() {'''
sub1(r"\nfunction startActiveTripTimers\(\) \{", helpers, label='helpers')

# --- auto-stop from the running timer ---
sub1(r"(secs = Math\.max\(0, Math\.floor\(\(Date\.now\(\) - activeTripStartedAtMs\) / 1000\)\);\n)(\s*document\.getElementById\('timer'\)\.textContent\s*=\s*window\.fmt\(secs\);)",
     r"\1    if (secs >= ACTIVE_TRIP_AUTO_STOP_MS / 1000) { autoStopActiveTrip(); return; }\n\2",
     label='timer auto-stop')

# --- restore: discard stale drafts, auto-stop long-running ones, keep stopped duration ---
sub1(r"function restoreActiveTripIfNeeded\(\) \{\n  const draft = getActiveTripDraft\(\);\n  if \(!draft \|\| draft\.uid !== currentUser\?\.uid \|\| !draft\.startedAtMs\) return false;\n  activeTripStartedAtMs = Number\(draft\.startedAtMs\) \|\| Date\.now\(\);",
     "function restoreActiveTripIfNeeded() {\n"
     "  const draft = getActiveTripDraft();\n"
     "  if (!draft || draft.uid !== currentUser?.uid || !draft.startedAtMs) return false;\n"
     "  const draftStartedAtMs = Number(draft.startedAtMs) || Date.now();\n"
     "  const draftAgeMs = Date.now() - draftStartedAtMs;\n"
     "  if (draftAgeMs > ACTIVE_TRIP_STALE_MS) {\n"
     "    // A draft this old is a trip nobody stopped: drop it instead of showing a days-long timer.\n"
     "    clearActiveTripDraft();\n"
     "    resetTripUI();\n"
     "    cancelTripNotifications();\n"
     "    showToast('An unsaved trip from ' + new Date(draftStartedAtMs).toLocaleDateString('en-AU') + ' was discarded (older than 2 days).', 7000);\n"
     "    return false;\n"
     "  }\n"
     "  activeTripStartedAtMs = draftStartedAtMs;",
     label='restore: stale draft')
sub1(r"  secs = Math\.max\(Number\(draft\.secs\) \|\| 0, Math\.floor\(\(Date\.now\(\) - activeTripStartedAtMs\) / 1000\)\);\n  purpose = draft\.purpose",
     "  secs = draft.status === 'stopped'\n"
     "    ? (Number(draft.secs) || 0)\n"
     "    : Math.max(Number(draft.secs) || 0, Math.floor((Date.now() - activeTripStartedAtMs) / 1000));\n"
     "  purpose = draft.purpose",
     label='restore: stopped duration')
sub1(r"  running = true;\n  lastPos = null;\n  showRunningTripUI\(\);\n  startActiveTripTimers\(\);\n  startGPS\(\);\n  showToast\('Trip still active\. LogM8 restored it from your last session\.', 5000\);\n  return true;",
     "  running = true;\n"
     "  lastPos = null;\n"
     "  if (draftAgeMs >= ACTIVE_TRIP_AUTO_STOP_MS) {\n"
     "    autoStopActiveTrip();\n"
     "    return true;\n"
     "  }\n"
     "  showRunningTripUI();\n"
     "  startActiveTripTimers();\n"
     "  startGPS();\n"
     "  scheduleTripNotifications(activeTripStartedAtMs);\n"
     "  showToast('Trip still active. LogM8 restored it from your last session.', 5000);\n"
     "  return true;",
     label='restore: auto-stop long trips')

# --- toggleTrip: continue to a new trip when a stale draft was discarded; native reminders ---
sub1(r"    if \(existingDraft\?\.startedAtMs && existingDraft\.uid === currentUser\?\.uid\) \{\n      restoreActiveTripIfNeeded\(\);\n      return;\n    \}",
     "    if (existingDraft?.startedAtMs && existingDraft.uid === currentUser?.uid) {\n"
     "      if (restoreActiveTripIfNeeded()) return;\n"
     "    }",
     label='toggleTrip: restore')
sub1(r"    saveActiveTripDraft\('running'\);\n    startActiveTripTimers\(\);\n    startGPS\(\);\n",
     "    saveActiveTripDraft('running');\n    startActiveTripTimers();\n    startGPS();\n    scheduleTripNotifications(activeTripStartedAtMs);\n",
     label='toggleTrip: schedule reminders')
sub1(r"    running=false;\n    stopActiveTripTimers\(\{ keepClock: true \}\);\n    stopGPS\(\);\n    manualTripEndKm = getGpsEstimatedEndKm\(\);",
     "    running=false;\n    stopActiveTripTimers({ keepClock: true });\n    stopGPS();\n    cancelTripNotifications();\n    manualTripEndKm = getGpsEstimatedEndKm();",
     label='toggleTrip: cancel reminders on stop')

# --- resetTripUI cancels reminders too (covers save + discard) ---
sub1(r"function resetTripUI\(\)\{\n  stopActiveTripTimers\(\);\n  stopGPS\(\);",
     "function resetTripUI(){\n  stopActiveTripTimers();\n  stopGPS();\n  cancelTripNotifications();",
     label='resetTripUI')

open(p, 'w', encoding='utf-8').write(s)
print('trip guard applied to', p)
