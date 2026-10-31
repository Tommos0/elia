// Minimal service worker so the browser treats Elia as an installable app.
// Elia is a live server-driven app: nothing is cached and requests are never
// proxied. The fetch handler deliberately does not answer requests itself, so
// the browser handles every request natively (PWA-4).
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))
self.addEventListener("fetch", () => {})
