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
  manifest whose `name` is "Elia", `start_url` and `scope` are `/` (the
  dashboard, DASH-1), `display`
  is `standalone`, and which has `background_color` and `theme_color`.
- **PWA-2** The manifest lists PNG icons of 192×192 and 512×512 for purpose
  `any` and for purpose `maskable`. Every icon file it references is served.
- **PWA-3** The root layout links the manifest (`rel="manifest"`, with
  `crossorigin="use-credentials"` so the browser sends cookies when fetching
  it; behind an auth proxy such as Cloudflare Access it is otherwise redirected
  to the login page and fails), sets a
  `theme-color` meta tag, and links a 180×180 `apple-touch-icon`.
- **PWA-4** `/sw.js` is served from the site root, so its scope covers the
  whole app. It has a `fetch` handler that never calls `respondWith`, so the
  browser handles every request natively (no caching, no proxying; proxying
  navigations through the worker can leave a blank page after a refresh), and
  it activates immediately (`skipWaiting` and `clients.claim`).
- **PWA-5** `assets/js/app.js` registers `/sw.js` when the browser supports
  service workers. A registration failure never breaks the page: it is logged,
  and the push section reports it (PUSH-19).
- **PWA-6** The icon PNGs are reproducible: `assets/pwa_icons.exs` generates
  them into `priv/static/images/`.
- **PWA-7** The root layout's viewport meta asks a mobile browser to resize the
  page when the on-screen keyboard appears (`interactive-widget=resizes-content`),
  so a phone's keyboard takes its room from the page instead of covering the
  bottom of it — the composer in a chat (UI-78). A browser that doesn't know the
  directive ignores it, and so does a desktop browser, where there is no
  keyboard to resize for.

## Out of scope

- Offline use, caching, push notifications.
- The browser only offers installation on a secure origin. Over plain HTTP on a
  LAN address, Chrome only offers a shortcut, not an installed app. Use HTTPS
  (e.g. a tunnel or reverse proxy) or `chrome://flags` "Insecure origins treated
  as secure".
- Behind an auth proxy (Cloudflare Access, HTTP basic auth), `/sw.js` has to be
  excluded from the login, or nothing installs and push cannot work (PUSH-19):
  unlike the manifest, which the page can fetch with credentials (PWA-3), a
  browser fetches a service worker script without them, so the login page comes
  back and the registration fails.

## Implementation

- `priv/static/manifest.webmanifest`, `priv/static/sw.js`,
  `priv/static/images/icon-*.png`, `priv/static/images/apple-touch-icon.png`
- `assets/pwa_icons.exs` (icon generator)
- `EliaWeb.static_paths/0` (serves the files), `root.html.heex` (head tags,
  the viewport meta of PWA-7), `assets/js/app.js` (registration)

## Tests

- `test/elia_web/pwa_test.exs` (the manifest and its icons, the layout's links,
  the service worker's scope and the viewport meta — PWA-1 to PWA-4, PWA-6,
  PWA-7).
- No test: PWA-5 — the registration is JavaScript in `assets/js/app.js`, the
  project has no JS test runner, and it is checked by hand.
