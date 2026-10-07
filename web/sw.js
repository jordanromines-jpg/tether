// Service worker: makes Tether installable, and keeps a copy of the page's own files (HTML, scripts,
// styles, icons) for when the Mac can't be reached. Always network first, so an updated Mac is picked
// up immediately; the saved copy is used only when the network fails, so the home-screen app can still
// open and explain what's wrong ("Studio is offline") instead of showing the browser's error page.
// API calls, the WebSocket and thumbnails are never cached.
const CACHE = 'tether-shell-v1';
const SHELL = /(?:\/|\.html|\.js|\.css|\.svg|\.png|\.webmanifest)$/;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== self.location.origin || !SHELL.test(url.pathname) || url.pathname.endsWith('/sw.js')) return;
  e.respondWith(fetch(e.request).then((response) => {
    if (response.ok) {
      const copy = response.clone();
      caches.open(CACHE).then((cache) => cache.put(url.pathname, copy)).catch(() => {});
    }
    return response;
  }).catch(() => caches.match(url.pathname).then((saved) => saved || Response.error())));
});
