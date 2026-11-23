import { useEffect, useRef, useState } from "react"
import RFB from "@novnc/novnc"
import { ArrowRightToLine, ChevronLeft, CornerDownLeft, Delete, Keyboard, Maximize, Minimize, RefreshCw, Send, X, ZoomIn, ZoomOut } from "lucide-react"
import { getToken } from "./api"

/**
 * A plain arrow for screens that send no pointer of their own: a Mac's Screen
 * Sharing neither draws it into the picture nor sends its shape to a client
 * that isn't Apple's, so without this the pointer is invisible. noVNC shows
 * its "dot" only while the server's own cursor is empty, so the arrow takes
 * the dot's place; a server that sends a cursor still has it shown.
 */
function arrowCursor() {
  const w = 13, h = 20
  const c = document.createElement("canvas")
  c.width = w
  c.height = h
  const g = c.getContext("2d")
  if (!g) return
  g.beginPath()
  for (const [x, y] of [[1, 1], [1, 16], [4.5, 12.5], [7, 18.5], [9.5, 17.5], [7, 11.5], [12, 11.5]]) g.lineTo(x, y)
  g.closePath()
  g.fillStyle = "#000"
  g.fill()
  g.strokeStyle = "#fff"
  g.lineWidth = 1.2
  g.stroke()
  const rgbaPixels = new Uint8Array(g.getImageData(0, 0, w, h).data.buffer)
  RFB.cursors.dot = { rgbaPixels, w, h, hotx: 1, hoty: 1 }
}
arrowCursor()

/** One of the user's devices whose screen the pane shows instead, over its forwarded port. */
export type DesktopTarget = { id: string; name: string }

/**
 * Loom's own browser — the Chromium that agents drive over CDP — shown here so
 * the user can take it over: log in to a site once, get past a check that
 * wants a human. Over VNC: `LoomWeb.VncSocket` carries it, noVNC draws it.
 *
 * On a phone the pane asks for a window of its own shape (see
 * `Loom.Browser`), so sites lay themselves out for a narrow screen and the
 * page fills the pane, rather than a desktop screen shrunk to unreadable.
 *
 * Given a `device`, the same pane shows that device's own screen instead: the
 * VNC server on it, through its forwarded port (`LoomWeb.ForwardSocket`). Its
 * VNC asks for its own password (a Mac's, its account name and password).
 *
 * Mounted only while shown, so a closed pane holds no connection open.
 */
export function Browser({
  narrow,
  maximized,
  onToggleMaximized,
  onClose,
  device,
}: {
  narrow: boolean
  maximized: boolean
  onToggleMaximized: () => void
  onClose: () => void
  device?: DesktopTarget
}) {
  const screen = useRef<HTMLDivElement>(null)
  const rfb = useRef<RFB | null>(null)
  const [state, setState] = useState<"connecting" | "connected" | "closed">("connecting")
  const [attempt, setAttempt] = useState(0)
  // Fit the whole screen in the pane, or show it at 1:1 and pan by dragging.
  const [fit, setFit] = useState(true)
  const [typing, setTyping] = useState(false)
  const [text, setText] = useState("")
  // What the device's VNC asks for before it shows the screen.
  const [asked, setAsked] = useState<string[] | null>(null)
  const [user, setUser] = useState("")
  const [pass, setPass] = useState("")
  const [why, setWhy] = useState<string | null>(null)

  useEffect(() => {
    const el = screen.current
    if (!el) return
    const proto = location.protocol === "https:" ? "wss:" : "ws:"
    const token = encodeURIComponent(getToken() ?? "")
    let url = device
      ? `${proto}//${location.host}/devices/${device.id}/forward?token=${token}`
      : `${proto}//${location.host}/browser/vnc?token=${token}`
    if (narrow && !device) url += `&w=${el.clientWidth}&h=${el.clientHeight}`
    const r = new RFB(el, url, { wsProtocols: [] })
    r.background = "transparent"
    r.showDotCursor = true
    // A replaced connection's goodbye arrives after its successor started.
    r.addEventListener("connect", () => {
      if (rfb.current !== r) return
      setState("connected")
      setAsked(null)
      setWhy(null)
    })
    r.addEventListener("disconnect", () => rfb.current === r && setState("closed"))
    r.addEventListener("credentialsrequired", (e) => {
      if (rfb.current !== r) return
      setAsked((e as CustomEvent<{ types: string[] }>).detail.types)
    })
    r.addEventListener("securityfailure", (e) => {
      if (rfb.current !== r) return
      const detail = (e as CustomEvent<{ reason?: string }>).detail
      setWhy(detail.reason || "wrong name or password")
    })
    rfb.current = r
    setState("connecting")
    return () => {
      rfb.current = null
      r.disconnect()
    }
  }, [attempt, narrow, device?.id])

  // A phone turned on its side wants a window of the other shape. The screen's
  // orientation, not the pane's: the keyboard coming up squashes the pane
  // without the phone having turned. Connect again once the pane has settled.
  useEffect(() => {
    if (!narrow) return
    let timer: number | undefined
    const turned = () => {
      clearTimeout(timer)
      timer = window.setTimeout(() => setAttempt((n) => n + 1), 400)
    }
    // Older iOS has no `screen.orientation`, only the window's event.
    const [target, event] = window.screen.orientation
      ? [window.screen.orientation, "change"]
      : [window, "orientationchange"]
    target.addEventListener(event, turned)
    return () => {
      clearTimeout(timer)
      target.removeEventListener(event, turned)
    }
  }, [narrow])

  useEffect(() => {
    const r = rfb.current
    if (!r) return
    r.scaleViewport = fit
    r.clipViewport = !fit
    r.dragViewport = !fit && narrow
  }, [fit, narrow, attempt, state])

  // A phone's keyboard won't come up for a canvas, so text goes in through a
  // field of our own and is typed into the page key by key.
  const send = (s: string) => {
    const r = rfb.current
    if (!r) return
    for (const ch of s) {
      const code = ch.codePointAt(0)!
      // X keysyms: Latin-1 is its own code point; the rest of Unicode is offset.
      r.sendKey(code < 0x100 ? code : 0x01000000 + code, null)
    }
  }
  const key = (keysym: number) => rfb.current?.sendKey(keysym, null)

  return (
    <div className="browser-pane">
      <div className="pane-head">
        <span className="pane-title">
          {narrow && (
            <button className="pane-btn" onClick={onClose} title="Back to the chat">
              <ChevronLeft />
            </button>
          )}
          {device ? device.name : "browser"}
          {state !== "connected" && (
            <span className="browser-state">
              {state === "closed" ? "disconnected" : asked ? "password needed" : "connecting…"}
            </span>
          )}
        </span>
        <span className="pane-actions">
          {state === "closed" && (
            <button className="pane-btn" onClick={() => setAttempt((n) => n + 1)} title="Connect again">
              <RefreshCw />
            </button>
          )}
          <button
            className={"pane-btn" + (typing ? " on" : "")}
            onClick={() => setTyping((t) => !t)}
            title="Type text into the page"
          >
            <Keyboard />
          </button>
          <button
            className="pane-btn"
            onClick={() => setFit((f) => !f)}
            title={fit ? "Actual size; drag to pan on a touch screen" : "Fit the screen in the pane"}
          >
            {fit ? <ZoomIn /> : <ZoomOut />}
          </button>
          {!narrow && (
            <button
              className="pane-btn"
              onClick={onToggleMaximized}
              title={maximized ? "Back beside the chat" : "Full window"}
            >
              {maximized ? <Minimize /> : <Maximize />}
            </button>
          )}
          {!narrow && (
            <button className="pane-btn" onClick={onClose} title="Close">
              <X />
            </button>
          )}
        </span>
      </div>
      {typing && (
        <form
          className="browser-type"
          onSubmit={(e) => {
            e.preventDefault()
            send(text)
            setText("")
          }}
        >
          <input
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder="Text for the focused field"
            autoCapitalize="off"
            autoCorrect="off"
            autoComplete="off"
            spellCheck={false}
          />
          <button type="submit" className="pane-btn" title="Type it">
            <Send />
          </button>
          <button type="button" className="pane-btn" onClick={() => key(0xff08)} title="Backspace">
            <Delete />
          </button>
          <button type="button" className="pane-btn" onClick={() => key(0xff09)} title="Tab">
            <ArrowRightToLine />
          </button>
          <button type="button" className="pane-btn" onClick={() => key(0xff0d)} title="Enter">
            <CornerDownLeft />
          </button>
        </form>
      )}
      {asked && state !== "closed" && (
        <form
          className="browser-type"
          onSubmit={(e) => {
            e.preventDefault()
            rfb.current?.sendCredentials({ username: user, password: pass })
            setPass("")
            setAsked(null)
          }}
        >
          {asked.includes("username") && (
            <input
              value={user}
              onChange={(e) => setUser(e.target.value)}
              placeholder="Account name"
              autoCapitalize="off"
              autoCorrect="off"
              autoComplete="username"
              spellCheck={false}
            />
          )}
          <input
            type="password"
            value={pass}
            onChange={(e) => setPass(e.target.value)}
            placeholder={asked.includes("username") ? "Password" : "VNC password"}
            autoComplete="current-password"
            autoFocus
          />
          <button type="submit" className="pane-btn" title="Log in">
            <Send />
          </button>
        </form>
      )}
      {why && state === "closed" && <div className="browser-type">{why}</div>}
      <div className="browser-screen" ref={screen} />
    </div>
  )
}
