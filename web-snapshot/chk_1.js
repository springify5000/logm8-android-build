
window.LOGM8_APP_CACHE_VERSION = 98;
(function(){
  if (window.Capacitor || !window.fetch) return;
  const currentVersion = Number(window.LOGM8_APP_CACHE_VERSION || 0);
  fetch('/version.json?check=' + Date.now(), { cache: 'no-store' })
    .then((response) => response && response.ok ? response.json() : null)
    .then(async (info) => {
      const requiredVersion = Number(info && (info.minCacheVersion || info.cacheVersion || 0));
      if (!requiredVersion || currentVersion >= requiredVersion) return;
      // Loop guard: this URL already is the repair reload for this version, so don't reload again.
      try {
        const here = new URLSearchParams(location.search);
        if (here.get('repair') === 'version' && here.get('v') === String(requiredVersion)) return;
      } catch (_) {}
      try {
        if ('serviceWorker' in navigator) {
          const regs = await navigator.serviceWorker.getRegistrations();
          await Promise.all(regs.map((registration) => registration.unregister()));
        }
        if ('caches' in window) {
          const keys = await caches.keys();
          await Promise.all(keys.filter((key) => key.indexOf('logm8-') === 0).map((key) => caches.delete(key)));
        }
      } catch (_) {}
      const nextUrl = new URL(location.href);
      nextUrl.pathname = '/app.html';
      nextUrl.searchParams.set('v', String(requiredVersion));
      nextUrl.searchParams.set('repair', 'version');
      nextUrl.searchParams.set('t', String(Date.now()));
      location.replace(nextUrl.href);
    })
    .catch(() => {});
})();
