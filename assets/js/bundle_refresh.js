// Loads the page again when the server serves another bundle than the one it
// loaded (see specs/bundle-refresh.md).
//
// An open page keeps the bundle it loaded: the live reload that would give it
// the new one (DEPLOY-12) is a reload it can miss — it was asleep, or its
// live-reload socket died with the server during a restart deploy, which is
// where the page comes back by reconnecting instead of by reloading (CONN-1).
// It then runs the old JavaScript against the new markup. So it asks the server
// which bundle it serves (BUNDLE-3) and compares that with the version this
// document carries (BUNDLE-2).

import {reloadAllowed} from "./reload_budget"

const CHECK_INTERVAL_MS = 60000 // BUNDLE-4

// The version this page loaded, or null on a page that carries none (BUNDLE-2).
function loadedVersion() {
  const meta = document.querySelector("meta[name='elia-asset-version']")
  return meta ? meta.content : null
}

// What the server serves now (BUNDLE-3), or null when the check failed
// (BUNDLE-7).
async function servedVersion() {
  try {
    const response = await fetch("/asset-version", {cache: "no-store"})
    return response.ok ? await response.text() : null
  } catch (_e) {
    return null
  }
}

export function bundleRefresh(liveSocket) {
  const loaded = loadedVersion()
  // A page of the app's own front end carries the version; one without it has
  // no bundle to be stale.
  if (!loaded) return

  let checking = false

  // BUNDLE-4, BUNDLE-5, BUNDLE-7: a check that fails changes nothing, and one
  // that finds another bundle reloads the page.
  const check = async () => {
    if (checking || document.visibilityState !== "visible") return
    checking = true
    const served = await servedVersion()
    checking = false
    if (served === null || served === loaded) return

    if (reloadAllowed()) {
      window.location.reload()
    } else {
      // BUNDLE-6: a reload this tab is not allowed any more, so it stays where
      // it is rather than looping.
      console.warn(
        "bundle refresh: the server serves another bundle than this page loaded, and this tab has reloaded too often to try again"
      )
    }
  }

  // BUNDLE-4: a socket that opens is a server that may have just come back on
  // another build (CONN-1); a tab that is shown again is one that made no
  // request while it was hidden.
  liveSocket.getSocket().onOpen(check)
  document.addEventListener("visibilitychange", check)
  window.addEventListener("pageshow", e => e.persisted && check())
  setInterval(check, CHECK_INTERVAL_MS)

  check()
}
