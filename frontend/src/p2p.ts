import { useSyncExternalStore } from "react"
import { authHeaders } from "./api"

/**
 * Settings' P2P switch (`Loom.P2P` on the server, for the whole instance):
 * whether a device's screen tries a direct, peer-to-peer channel before
 * loom's relay. Cached here so the VNC pane knows at once; the server's
 * answer corrects it.
 */
const KEY = "loom_p2p"
let on = localStorage.getItem(KEY) === "1"
const listeners = new Set<() => void>()

function set(next: boolean) {
  on = next
  localStorage.setItem(KEY, next ? "1" : "0")
  for (const l of listeners) l()
}

export const p2pOn = () => on

export async function refreshP2p() {
  try {
    const res = await fetch("/api/p2p", { headers: authHeaders() })
    if (res.ok) set((await res.json()).on === true)
  } catch {
    // Offline: the cached answer stands.
  }
}

export async function saveP2p(next: boolean) {
  set(next)
  const res = await fetch("/api/p2p", {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ on: next }),
  })
  if (res.ok) set((await res.json()).on === true)
  else void refreshP2p()
}

export function subscribeP2p(l: () => void) {
  listeners.add(l)
  return () => {
    listeners.delete(l)
  }
}

export function useP2p(): boolean {
  return useSyncExternalStore(subscribeP2p, p2pOn)
}
