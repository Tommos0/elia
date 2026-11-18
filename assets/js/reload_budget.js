// The tab's reload budget (CONN-5, BUNDLE-6).
//
// A page gives itself a reload in two cases — its socket is dead and does not
// come back (assets/js/auto_reconnect.js) and the server serves a bundle other
// than the one it loaded (assets/js/bundle_refresh.js) — and both are counted
// here, in one place: what a runaway reload loop costs is the tab, not the
// reason it asked, so a tab reloads at most MAX_RELOADS times a minute whatever
// asked for it.

const MAX_RELOADS = 3
const RELOAD_WINDOW_MS = 60000
const RELOAD_KEY = "elia:reloads"

// Whether this tab may reload now, counting the reload it allows.
export function reloadAllowed() {
  const now = Date.now()
  let times = []
  try {
    times = JSON.parse(sessionStorage.getItem(RELOAD_KEY) || "[]")
  } catch (_e) {
    times = []
  }
  times = times.filter(t => now - t < RELOAD_WINDOW_MS)
  if (times.length >= MAX_RELOADS) return false
  times.push(now)
  try {
    sessionStorage.setItem(RELOAD_KEY, JSON.stringify(times))
  } catch (_e) {
    // Without storage we can't count, so don't risk a reload loop.
    return false
  }
  return true
}
