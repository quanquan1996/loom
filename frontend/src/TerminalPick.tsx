import { Monitor, Server } from "lucide-react"
import { useEffect, useLayoutEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"

// Where a new terminal runs: this server or one of the online devices. A menu
// of buttons rather than a native select laid invisibly over the "+": in an
// app opened from the iOS home screen such a select would not open on a tap.
export function TerminalPick({
  anchor,
  devices,
  onPick,
  onClose,
}: {
  anchor: DOMRect
  devices: string[]
  onPick: (node?: string) => void
  onClose: () => void
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [place, setPlace] = useState<{ top: number; left: number } | null>(null)

  useLayoutEffect(() => {
    const width = ref.current?.offsetWidth ?? 208
    const left = Math.min(Math.max(8, anchor.right - width), window.innerWidth - width - 8)
    setPlace({ top: anchor.bottom + 4, left })
  }, [anchor])

  useEffect(() => {
    // Not the "+" it opened from, whose click toggles it on its own.
    const away = (e: Event) => {
      if (ref.current?.contains(e.target as Node)) return
      if ((e.target as Element | null)?.closest?.(".pane-pick")) return
      onClose()
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return
      e.stopPropagation()
      onClose()
    }
    document.addEventListener("mousedown", away)
    document.addEventListener("touchstart", away)
    window.addEventListener("keydown", onKey, true)
    return () => {
      document.removeEventListener("mousedown", away)
      document.removeEventListener("touchstart", away)
      window.removeEventListener("keydown", onKey, true)
    }
  }, [onClose])

  const pick = (node?: string) => {
    onClose()
    onPick(node)
  }

  return createPortal(
    <div
      ref={ref}
      className="session-menu"
      role="menu"
      style={place ? { top: place.top, left: place.left } : { visibility: "hidden" }}
    >
      <button role="menuitem" onClick={() => pick()}>
        <Server /> On this server
      </button>
      {devices.map((name) => (
        <button role="menuitem" key={name} onClick={() => pick(name)}>
          <Monitor /> On {name}
        </button>
      ))}
    </div>,
    document.body,
  )
}
