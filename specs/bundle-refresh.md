# Bundle refresh

Status: Implemented

A page that is already open keeps the bundle it loaded. A deploy builds the
front end again (DEPLOY-19, DEPLOY-31) and what gives an open page the new
bundle is the browser's live reload (DEPLOY-12) — a reload a tab can miss: it
was asleep, or its live-reload socket died with the server during a "Restart"
deploy (DEPLOY-7), which is exactly the case where the page comes back on its
own instead of by reloading (CONN-1). The page then runs the JavaScript and the
stylesheet of the build before it against the markup of the build after it: a
hook the new markup asks for does not exist in the old bundle, a class it uses
has no rule. That is a stale browser bundle, and no page notices it.

So the page asks the server which bundle it serves now, and loads itself again
when the answer is not the one it loaded. This is client-side JavaScript
(`assets/js/bundle_refresh.js`, started from `assets/js/app.js`), and the answer
comes from an endpoint of its own.

## Requirements

- **BUNDLE-1** `EliaWeb.AssetVersion.current/1` is the version of the bundle a
  tree serves: the versions of the two entry points the endpoint serves
  (DEPLOY-24), `assets/css/app.css` and `assets/js/app.js` under the app's own
  `priv/static`, each read from the built file the way PWA-8 reads one — its
  modification time and its size — as one string naming both,
  `css=<version>;js=<version>`.
- **BUNDLE-2** The root layout writes that string into the document it serves,
  as the content of a `<meta name="elia-asset-version">`, so a page carries the
  version of the bundle it loaded.
- **BUNDLE-3** `GET /asset-version` answers with the tree's current version
  (BUNDLE-1) as plain text, served through the browser pipeline, so a client
  asking for it is never answered from a cache (PWA-9).
- **BUNDLE-4** The page compares the version it loaded (BUNDLE-2) with the one
  the server serves (BUNDLE-3) when it loads, when the LiveView socket opens or
  opens again (CONN-1), when the tab becomes visible again or the page is
  restored from the back/forward cache, and every 60 seconds while the tab is
  visible. A hidden tab makes no request: it checks when it is shown again.
- **BUNDLE-5** When the two differ, the page reloads itself, so an open page
  comes back on the bundle the deploy built (DEPLOY-19, DEPLOY-24) rather than
  keeping the one it loaded (HOT-8).
- **BUNDLE-6** Reloads are limited to 3 per minute per tab, counted in
  `sessionStorage` in the same budget CONN-5 counts its own in, so a server
  whose answer a reload cannot change — a proxy serving one build's bundle with
  another build's version — cannot cause a reload loop; past the limit the page
  stops reloading and says so in the browser's console.
- **BUNDLE-7** A check that fails — offline, the server down, a response that is
  not 200 — changes nothing: nothing is shown, nothing is reloaded, and the next
  check tries again.

## Out of scope

- Warning the user first, or offering a control: the page loads itself again
  rather than asking, and a reload loses what is typed into the composer but not
  sent, the way CONN's reload does.
- The browser's cache of an asset URL, which the version query already answers
  (PWA-8), and the document's own cache (PWA-9).
- Offline use, and any caching by the service worker (PWA-4).
- A deploy that changes only Elixir code: it reaches an open page as markup
  (HOT-8), the bundle does not change, and there is nothing to refresh.
- A page that is not the app's own: `/recover` is plain HTML with none of the
  tree's front end (RECOVER-1).

## Implementation

- `EliaWeb.AssetVersion.current/1` (the version string, BUNDLE-1)
- `EliaWeb.AssetVersionController` and `lib/elia_web/router.ex` (the route,
  BUNDLE-3)
- `lib/elia_web/components/layouts/root.html.heex` (the meta, BUNDLE-2)
- `assets/js/bundle_refresh.js` and `assets/js/app.js` (the checks and the
  reload, BUNDLE-4 to BUNDLE-7)
- `assets/js/reload_budget.js` (the tab's reload budget, which
  `assets/js/auto_reconnect.js` counts in as well, CONN-5, BUNDLE-6)

## Tests

- `test/elia_web/bundle_refresh_test.exs` (the version a tree serves, the
  endpoint and its cache header, the meta a page carries — BUNDLE-1 to
  BUNDLE-3).
- `test/elia_web/bundle_refresh_js_test.exs` (the module exists, is wired into
  `app.js`, and carries the interval, the triggers, the reload and the budget it
  shares — BUNDLE-4 to BUNDLE-7).
- No test: BUNDLE-5, BUNDLE-7 — the reload itself and what a failed check does
  are JavaScript in `assets/js/bundle_refresh.js`, the project has no JS test
  runner, so only the wiring above is tested and the behaviour is checked by
  hand: with the assets built, open a page, build them again, and the page comes
  back on its own; with the server stopped, a page is left as it is.
