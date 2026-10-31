# Installable web app (PWA)

Status: Implemented

Elia can be installed on a phone's home screen (Android Chrome: menu →
"Install app" / "Add to Home screen") and then opens in its own window without
the browser chrome. This needs a web app manifest, icons, a registered service
worker, and a secure origin (HTTPS, or `localhost`). Elia is a live,
server-driven app, so the service worker does no caching and there is no
offline mode.

## Requirements

- **PWA-1** `/manifest.webmanifest` is served as a static file with a JSON
  manifest whose `name` is "Elia", `start_url` and `scope` are `/`, `display`
  is `standalone`, and which has `background_color` and `theme_color`.
- **PWA-2** The manifest lists PNG icons of 192×192 and 512×512 for purpose
  `any` and for purpose `maskable`. Every icon file it references is served.
- **PWA-3** The root layout links the manifest (`rel="manifest"`), sets a
  `theme-color` meta tag, and links a 180×180 `apple-touch-icon`.
- **PWA-4** `/sw.js` is served from the site root, so its scope covers the
  whole app. It has a `fetch` handler that never calls `respondWith`, so the
  browser handles every request natively (no caching, no proxying; proxying
  navigations through the worker can leave a blank page after a refresh), and
  it activates immediately (`skipWaiting` and `clients.claim`).
- **PWA-5** `assets/js/app.js` registers `/sw.js` when the browser supports
  service workers. A registration failure is ignored (logged only) and never
  breaks the page.
- **PWA-6** The icon PNGs are reproducible: `assets/pwa_icons.exs` generates
  them into `priv/static/images/`.

## Out of scope

- Offline use, caching, push notifications.
- The browser only offers installation on a secure origin. Over plain HTTP on a
  LAN address, Chrome only offers a shortcut, not an installed app. Use HTTPS
  (e.g. a tunnel or reverse proxy) or `chrome://flags` "Insecure origins treated
  as secure".

## Implementation

- `priv/static/manifest.webmanifest`, `priv/static/sw.js`,
  `priv/static/images/icon-*.png`, `priv/static/images/apple-touch-icon.png`
- `assets/pwa_icons.exs` (icon generator)
- `EliaWeb.static_paths/0` (serves the files), `root.html.heex` (head tags),
  `assets/js/app.js` (registration)

## Tests

- `test/elia_web/pwa_test.exs`. PWA-5 (JS registration) is checked by hand, as
  there is no JS test runner.
