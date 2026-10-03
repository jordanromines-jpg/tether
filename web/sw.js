// Pass-through service worker: makes the app installable without caching
// anything, so a redeployed agent is always picked up immediately.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
