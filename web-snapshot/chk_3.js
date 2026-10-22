
// Service worker (web only - Capacitor handles caching natively)
if (!window.Capacitor && 'serviceWorker' in navigator) {
  (async () => {
    try {
      const CLEAN_KEY = `logm8_sw_cleanup_v${String(window.LOGM8_APP_CACHE_VERSION)}_done`;
      let cleanupStore = sessionStorage;
      try {
        localStorage.setItem('__logm8_storage_test', '1');
        localStorage.removeItem('__logm8_storage_test');
        cleanupStore = localStorage;
      } catch (_storageError) {}
      if (!cleanupStore.getItem(CLEAN_KEY)) {
        const regs = await navigator.serviceWorker.getRegistrations();
        await Promise.all(regs.map((reg) => reg.unregister()));
        if ('caches' in window) {
          const keys = await caches.keys();
          await Promise.all(
            keys
              .filter((key) => key.startsWith('logm8-'))
              .map((key) => caches.delete(key))
            );
        }
        cleanupStore.setItem(CLEAN_KEY, '1');
      }
    } catch (_e) {}
    const registration = await navigator.serviceWorker.register('/sw.js?v=87');
    try {
      registration.update();
      if (registration.waiting) registration.waiting.postMessage({ type: 'SKIP_WAITING' });
    } catch (_) {}
    navigator.serviceWorker.addEventListener('message', (event) => {
      if (event?.data?.type !== 'LOGM8_SW_UPDATE_READY') return;
      checkForFreshAppVersion({ silent: false, reason: 'sw-message' });
    });
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      if (window.__logm8ControllerReloaded) return;
      window.__logm8ControllerReloaded = true;
      window.__logm8AutoUpdating = true;
      if (typeof protectActiveTrip === 'function') protectActiveTrip('controllerchange');
      const cacheVersion = String(window.LOGM8_APP_CACHE_VERSION);
      const nextUrl = new URL(location.href);
      nextUrl.pathname = '/app.html';
      nextUrl.searchParams.set('v', String(cacheVersion));
      nextUrl.searchParams.set('controller', '1');
      nextUrl.searchParams.set('t', String(Date.now()));
      location.replace(nextUrl.href);
    });
    window.addEventListener('pageshow', () => checkForFreshAppVersion({ reason: 'pageshow' }));
    window.addEventListener('focus', () => checkForFreshAppVersion({ reason: 'focus' }));
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) checkForFreshAppVersion({ reason: 'visible' });
    });
    setInterval(() => checkForFreshAppVersion({ reason: 'interval' }), 2 * 60 * 1000);
  })();
}
