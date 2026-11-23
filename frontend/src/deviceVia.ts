// How each device's open screen travels (the VNC pane, `Browser.tsx`), for the
// Devices dialog to show; kept apart so the dialog doesn't load noVNC.
export type Via = "direct" | "relay" | "retrying"

export const deviceVia = new Map<string, Via>()

export function reportVia(id: string, via: Via | null) {
  if (via) deviceVia.set(id, via)
  else deviceVia.delete(id)
  window.dispatchEvent(new Event("loom-device-via"))
}

// Devices whose screen tries a direct, peer-to-peer channel first. The
// page's alone: a reload, or another tab, starts with P2P off everywhere, so
// no direct path is ever tried that the user didn't just ask for.
export const p2pOn = new Set<string>()

export function setP2pOn(id: string, on: boolean) {
  if (on) p2pOn.add(id)
  else p2pOn.delete(id)
  window.dispatchEvent(new Event("loom-device-via"))
}
