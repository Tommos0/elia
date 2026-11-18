# Installable web app (PWA)

Status: Implemented

Elia can be installed on a phone's home screen (Android Chrome: menu →
"Install app" / "Add to Home screen") and then opens in its own window without
the browser chrome. This needs a web app manifest, icons, a registered service
worker, and a secure origin (HTTPS, or `localhost`). Elia is a live,
server-driven app, so the service worker does no caching and there is no
offline mode. What a browser's own cache can still hold on to is the page's
assets, so the shell's links to them carry a version that changes with the
build (PWA-8), and the documents themselves are served to be revalidated rather
than reused (PWA-9).

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
- **PWA-8** The root layout's links to the shell's own CSS and JS carry a
  version query, `?v=<version>`, whose value is read from the built file itself
  — its modification time and size — so a rebuild gives the page a new URL for
  the bundle. A page that loads again on a new build (an installed app reopened,
  a reload) therefore fetches the new bundle rather than one the browser's cache
  still holds, which is the case the worker does not cover (PWA-4). The version
  is read from the app's own `priv/static` as the layout renders, and a bundle
  that is not there yet gives a stable placeholder rather than an error, so a
  page renders before the assets are built.
- **PWA-9** The app's HTML documents are served telling the browser to
  revalidate them (`cache-control: no-cache`), so an installed app that loads
  its document again asks the server for it rather than being shown a copy the
  browser's cache still holds. Every page the browser pipeline serves gets it.
  It is not `no-store`: a page restored from the back/forward cache is how a tab
  left in the background recovers (CONN-1), and `no-store` is what keeps a
  browser from storing one at all.

## Out of scope

- Offline use, caching, push notifications.
- The document itself: the HTML an installed app opens carries no version — it
  revalidates with the server instead (PWA-9). What a page does when the bundle
  it loaded is no longer the one served is not this spec's: that is the page
  asking the server itself and loading again (`specs/bundle-refresh.md`,
  BUNDLE-4, BUNDLE-5).
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
  the viewport meta of PWA-7, the versioned asset links of PWA-8),
  `assets/js/app.js` (registration)
- `EliaWeb.AssetVersion` (the version of PWA-8)
- `EliaWeb.Router` (the browser pipeline's `no-cache` on documents, PWA-9)

## Tests

- `test/elia_web/pwa_test.exs` (the manifest and its icons, the layout's links,
  the service worker's scope and the viewport meta, the version on the asset
  links, the document's cache header — PWA-1 to PWA-4, PWA-6 to PWA-9).
- No test: PWA-5 — the registration is JavaScript in `assets/js/app.js`, the
  project has no JS test runner, and it is checked by hand.
