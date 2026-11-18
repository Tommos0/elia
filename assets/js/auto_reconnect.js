// Keeps a LiveView page usable after its socket died (see specs/auto-reconnect.md).

import {reloadAllowed} from "./reload_budget"

const HEARTBEAT_TIMEOUT_MS = 5000 // CONN-2
const STALL_MS = 10000 // CONN-4

const visible = () => document.visibilityState === "visible"

export function autoReconnect(liveSocket) {
  const socket = liveSocket.getSocket()
  let stallTimer = null
  let heartbeatTimer = null

  const clearStall = () => {
    clearTimeout(stallTimer)
    stallTimer = null
  }

  // CONN-3 / CONN-4: the stall timer, and the reload it may end in — the
  // budget it counts in is the tab's, shared with the bundle refresh (CONN-5,
  // BUNDLE-6).
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
