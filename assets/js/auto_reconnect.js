// Keeps a LiveView page usable after its socket died (see specs/auto-reconnect.md).

const HEARTBEAT_TIMEOUT_MS = 5000 // CONN-2
const STALL_MS = 10000 // CONN-4
const MAX_RELOADS = 3 // CONN-5
const RELOAD_WINDOW_MS = 60000
const RELOAD_KEY = "elia:reloads"

const visible = () => document.visibilityState === "visible"

function reloadAllowed() {
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

export function autoReconnect(liveSocket) {
  const socket = liveSocket.getSocket()
  let stallTimer = null
  let heartbeatTimer = null

  const clearStall = () => {
    clearTimeout(stallTimer)
    stallTimer = null
  }

  // CONN-3 / CONN-4
  const armStall = () => {
    if (stallTimer) return
    stallTimer = setTimeout(() => {
      stallTimer = null
      if (visible() && !liveSocket.isConnected() && reloadAllowed()) window.location.reload()
    }, STALL_MS)
  }

  // CONN-1: skip the backoff and connect now.
  const reconnectNow = () => {
    armStall()
    liveSocket.disconnect(() => liveSocket.connect())
  }

  // CONN-1 / CONN-2
  const check = () => {
    if (!visible()) return
    if (!liveSocket.isConnected()) return reconnectNow()

    clearTimeout(heartbeatTimer)
    heartbeatTimer = setTimeout(reconnectNow, HEARTBEAT_TIMEOUT_MS)
    const sent = socket.ping(() => clearTimeout(heartbeatTimer))
    if (!sent) {
      clearTimeout(heartbeatTimer)
      reconnectNow()
    }
  }

  socket.onOpen(clearStall)
  socket.onClose(armStall)
  socket.onError(armStall)

  document.addEventListener("visibilitychange", check)
  window.addEventListener("pageshow", e => e.persisted && check())
  window.addEventListener("online", check)
}
