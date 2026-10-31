// Minimal service worker so the browser treats Elia as an installable app.
// Elia is a live server-driven app: nothing is cached, every request goes to
// the network unchanged (PWA-4).
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))
self.addEventListener("fetch", event => event.respondWith(fetch(event.request)))
