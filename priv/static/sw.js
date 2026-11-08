// Minimal service worker so the browser treats Elia as an installable app.
// Elia is a live server-driven app: nothing is cached and requests are never
// proxied. The fetch handler deliberately does not answer requests itself, so
// the browser handles every request natively (PWA-4).
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))
self.addEventListener("fetch", () => {})

// PUSH-10: a notification Elia sent because a chat needs the user. The payload
// is the JSON of PUSH-9 — title, body, url, tag and icon — and `tag` is what
// lets a newer notification for the same chat replace the one still showing
// instead of piling up beside it.
self.addEventListener("push", event => {
  let payload = {}
  try {
    payload = event.data ? event.data.json() : {}
  } catch (error) {
    console.warn("push: payload is not JSON", error)
  }

  const icon = payload.icon || "/images/icon-192.png"

  event.waitUntil(
    self.registration.showNotification(payload.title || "Elia", {
      body: payload.body || "",
      icon: icon,
      badge: icon,
      tag: payload.tag || "elia",
      data: {url: payload.url || "/"}
    })
  )
})

// PUSH-10: clicking a notification opens (or brings forward) the tab it is
// about, rather than opening a second copy of Elia.
self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || "/"

  event.waitUntil(
    self.clients.matchAll({type: "window", includeUncontrolled: true}).then(clients => {
      const client = clients.find(one => new URL(one.url).origin === self.location.origin)
      if (!client) return self.clients.openWindow(url)
      if (new URL(client.url).pathname === url) return client.focus()
      return client.navigate(url).then(navigated => (navigated || client).focus())
    })
  )
})
