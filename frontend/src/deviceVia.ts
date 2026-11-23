// How each device's open screen travels (the VNC pane, `Browser.tsx`), for the
// Devices dialog to show; kept apart so the dialog doesn't load noVNC.
export type Via = "direct" | "relay" | "retrying"

export const deviceVia = new Map<string, Via>()

export function reportVia(id: string, via: Via | null) {
  if (via) deviceVia.set(id, via)
  else deviceVia.delete(id)
  window.dispatchEvent(new Event("loom-device-via"))
}

