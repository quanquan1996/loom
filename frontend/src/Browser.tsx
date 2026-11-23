import { useEffect, useRef, useState } from "react"
import RFB from "@novnc/novnc"
import { ArrowRightToLine, ChevronLeft, CornerDownLeft, Delete, Keyboard, Maximize, Minimize, RefreshCw, Send, X, ZoomIn, ZoomOut } from "lucide-react"
import { getToken } from "./api"
import { p2pOn, reportVia, type Via } from "./deviceVia"

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

/** Public STUN servers, for the browser to learn its address beyond its NAT. */
const STUN = ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478", "stun:stun.miwifi.com:3478"]

/** A device's screen connection: straight to it, or relayed through loom. */
type DeviceLink = { chan: WebSocket | RTCDataChannel; ws: WebSocket; pc?: RTCPeerConnection; via: "direct" | "relay" }

function within<T>(ms: number, p: Promise<T>): Promise<T> {
  return Promise.race([p, new Promise<T>((_, no) => setTimeout(() => no(new Error("timed out")), ms))])
}

/**
 * Open a device's forwarded port, peer to peer when the browser and the device
 * can reach each other (`LoomWeb.ForwardSocket`, "Peer to peer"): the
 * WebSocket carries the WebRTC offer and answer, then stays open beside the
 * data channel so switching forwarding off still ends it. When no channel
 * opens in a few seconds, the same WebSocket carries the screen instead — or,
 * for a retry while relayed already (`fallback` false), it closes and null.
 */
async function openDevice(url: string, fallback = true): Promise<DeviceLink | null> {
  const ws = new WebSocket(url + "&rtc=1")
  ws.binaryType = "arraybuffer"
  // Registered before noVNC's onmessage, so a late handshake message never reaches it.
  const texts: ((m: { type: string; sdp?: string; message?: string }) => void)[] = []
  ws.addEventListener("message", (e) => {
    if (typeof e.data !== "string") return
    e.stopImmediatePropagation()
    try {
      const m = JSON.parse(e.data)
      texts.forEach((f) => f(m))
    } catch {}
  })
  await new Promise<void>((ok, no) => {
    ws.addEventListener("open", () => ok(), { once: true })
    ws.addEventListener("close", () => no(new Error("closed")), { once: true })
  })
  if (typeof RTCPeerConnection === "undefined") {
    if (!fallback) return ws.close(), null
    ws.send(JSON.stringify({ type: "fallback" }))
    return { chan: ws, ws, via: "relay" }
  }
  const pc = new RTCPeerConnection({ iceServers: [{ urls: STUN }] })
  try {
    const dc = pc.createDataChannel("vnc", { ordered: true })
    dc.binaryType = "arraybuffer"
    const opened = new Promise<void>((ok, no) => {
      dc.addEventListener("open", () => ok(), { once: true })
      dc.addEventListener("close", () => no(new Error("closed")), { once: true })
    })
    await pc.setLocalDescription(await pc.createOffer())
    await within(
      1500,
      new Promise<void>((ok) => {
        if (pc.iceGatheringState === "complete") ok()
        pc.addEventListener("icegatheringstatechange", () => pc.iceGatheringState === "complete" && ok())
      }),
    ).catch(() => {})
    const answer = new Promise<string>((ok, no) =>
      texts.push((m) => (m.type === "answer" && m.sdp ? ok(m.sdp) : m.type === "error" && no(new Error(m.message)))),
    )
    ws.send(JSON.stringify({ type: "offer", sdp: JSON.stringify(pc.localDescription) }))
    await pc.setRemoteDescription(JSON.parse(await within(6000, answer)))
    await within(3000, opened)
    return { chan: dc, ws, pc, via: "direct" }
  } catch {
    pc.close()
    if (!fallback) return ws.close(), null
    if (ws.readyState !== WebSocket.OPEN) throw new Error("closed")
    ws.send(JSON.stringify({ type: "fallback" }))
    return { chan: ws, ws, via: "relay" }
  }
}

// While relayed, how long until trying for a direct channel again: the network
// may change under a phone (Wi-Fi to 5G), so keep trying, ever less often.
const RETRY_MS = [15_000, 30_000, 60_000, 120_000, 300_000]

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
  // Each new connection under the pane, for the view settings to reach it.
  const [gen, setGen] = useState(0)
  const [typing, setTyping] = useState(false)
  const [text, setText] = useState("")
  // What the device's VNC asks for before it shows the screen.
  const [asked, setAsked] = useState<string[] | null>(null)
  const [user, setUser] = useState("")
  const [pass, setPass] = useState("")
  const [why, setWhy] = useState<string | null>(null)
  // How a device's screen travels: straight to it, or through loom.
  const [via, setVia] = useState<Via | null>(null)
  useEffect(() => {
    if (!device) return
    reportVia(device.id, state === "connected" ? via : null)
    return () => reportVia(device.id, null)
  }, [device?.id, via, state])
  // What the user logged in with, for this pane only: moving to a direct
  // channel, or back after a drop, logs in again without asking.
  const creds = useRef<{ username: string; password: string } | null>(null)

  useEffect(() => {
    const el = screen.current
    if (!el) return
    const proto = location.protocol === "https:" ? "wss:" : "ws:"
    const token = encodeURIComponent(getToken() ?? "")
    let url = device
      ? `${proto}//${location.host}/devices/${device.id}/forward?token=${token}`
      : `${proto}//${location.host}/browser/vnc?token=${token}`
    if (narrow && !device) url += `&w=${el.clientWidth}&h=${el.clientHeight}`
    let r: RFB | null = null
    let link: DeviceLink | null = null
    let gone = false
    let touched = 0
    let retry: number | undefined
    let tries = 0
    // Peer to peer, loom doesn't see the user's keys: tell it they're at work.
    const touch = () => {
      const now = Date.now()
      if (link?.via !== "direct" || now - touched < 60_000) return
      touched = now
      if (link.ws.readyState === WebSocket.OPEN) link.ws.send(JSON.stringify({ type: "touch" }))
    }
    el.addEventListener("pointerdown", touch, true)
    el.addEventListener("keydown", touch, true)

    const p2p = () => !!device && p2pOn.has(device.id)
    const drop = (l: DeviceLink | null) => {
      l?.ws.close()
      l?.pc?.close()
    }

    const start = (target: string | WebSocket | RTCDataChannel) => {
      const c = new RFB(el, target as string, { wsProtocols: [] })
      const old = r
      r = c
      c.background = "transparent"
      c.showDotCursor = true
      // A replaced connection's goodbye arrives after its successor started.
      c.addEventListener("connect", () => {
        if (rfb.current !== c) return
        setState("connected")
        setAsked(null)
        setWhy(null)
      })
      c.addEventListener("disconnect", (e) => {
        if (rfb.current !== c) return
        const wasDirect = link?.via === "direct"
        drop(link)
        link = null
        // A direct channel lost with the network: connect again, straight away.
        if (wasDirect && !(e as CustomEvent<{ clean: boolean }>).detail.clean && !gone) connect()
        else setState("closed")
      })
      c.addEventListener("credentialsrequired", (e) => {
        if (rfb.current !== c) return
        // Moving to a direct channel, or back after a drop: log in as before.
        if (creds.current) return c.sendCredentials(creds.current)
        setAsked((e as CustomEvent<{ types: string[] }>).detail.types)
      })
      c.addEventListener("securityfailure", (e) => {
        if (rfb.current !== c) return
        creds.current = null
        const detail = (e as CustomEvent<{ reason?: string }>).detail
        setWhy(detail.reason || "wrong name or password")
      })
      rfb.current = c
      setGen((n) => n + 1)
      old?.disconnect()
    }

    // Relayed with P2P on: try again in the background, and move over when
    // a direct channel opens.
    const later = () => {
      clearTimeout(retry)
      if (gone || !p2p() || link?.via !== "relay") return
      retry = window.setTimeout(upgrade, RETRY_MS[Math.min(tries++, RETRY_MS.length - 1)])
    }
    const upgrade = async () => {
      if (gone || link?.via !== "relay") return
      setVia("retrying")
      const l = await openDevice(url, false).catch(() => null)
      if (gone || link?.via !== "relay") return drop(l)
      if (!l) return setVia("relay"), later()
      const old = link
      link = l
      setVia("direct")
      l.ws.addEventListener("close", () => l.pc?.close())
      start(l.chan)
      drop(old)
    }
    const online = () => {
      tries = 0
      if (link?.via === "relay") upgrade()
    }
    window.addEventListener("online", online)
    // P2P is switched in the Devices dialog while the screen is open: off
    // closes a direct channel at once (back through loom); on tries for one.
    let wanted = p2p()
    const switched = () => {
      if (p2p() === wanted) return
      wanted = p2p()
      if (!wanted && link && link.via !== "relay") {
        // Unhooked first, so its goodbye doesn't read as the screen closing.
        rfb.current = null
        r?.disconnect()
        const old = link
        link = null
        drop(old)
        connect()
      }
      else if (!wanted) setVia(null), clearTimeout(retry)
      else if (link?.via === "relay") (tries = 0), upgrade()
    }
    window.addEventListener("loom-device-via", switched)

    const connect = () => {
      setState("connecting")
      setVia(null)
      if (!device) return start(url)
      const relayed = (): DeviceLink => {
        const ws = new WebSocket(url)
        return { chan: ws, ws, via: "relay" }
      }
      const opening = p2p() ? openDevice(url) : Promise.resolve(relayed())
      opening.then(
        (l) => {
          if (gone || !l) return drop(l)
          link = l
          setVia(p2p() ? l.via : null)
          // The switch going off closes the socket; a direct channel goes with it.
          if (l.via === "direct") l.ws.addEventListener("close", () => l.pc?.close())
          start(l.chan)
          later()
        },
        () => !gone && setState("closed"),
      )
    }
    connect()

    return () => {
      gone = true
      clearTimeout(retry)
      window.removeEventListener("online", online)
      window.removeEventListener("loom-device-via", switched)
      el.removeEventListener("pointerdown", touch, true)
      el.removeEventListener("keydown", touch, true)
      rfb.current = null
      r?.disconnect()
      drop(link)
    }
    // A device's screen is the size it is, so the pane's shape doesn't matter
    // to it: turning the phone (which crosses `narrow`) only rescales, rather
    // than reconnecting and asking for the password again.
  }, [attempt, device ? device.id : narrow])

  // A phone turned on its side wants a window of the other shape. The screen's
  // orientation, not the pane's: the keyboard coming up squashes the pane
  // without the phone having turned. Connect again once the pane has settled.
  useEffect(() => {
    if (!narrow || device) return
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
  }, [narrow, device])

  useEffect(() => {
    const r = rfb.current
    if (!r) return
    r.scaleViewport = fit
    r.clipViewport = !fit
    r.dragViewport = !fit && narrow
  }, [fit, narrow, attempt, state, gen])

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
          {device && via && state === "connected" && (
            <span
              className="browser-state"
              title={
                via === "direct"
                  ? "Straight to the device, peer to peer"
                  : "Through loom: no direct path yet; trying again now and then"
              }
            >
              {via === "retrying" ? "relay · retrying" : via}
            </span>
          )}
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
      <div className="browser-stage">
        <div className="browser-screen" ref={screen} />
        {asked && state !== "closed" && (
          <form
            className="vnc-login"
            onSubmit={(e) => {
              e.preventDefault()
              creds.current = { username: user, password: pass }
              rfb.current?.sendCredentials(creds.current)
              setPass("")
              setAsked(null)
            }}
          >
            <div className="vnc-login-title">Log in to {device?.name ?? "the screen"}</div>
            <div className="vnc-login-hint">
              {asked.includes("username")
                ? "Its own account name and password"
                : "The password of its VNC server"}
            </div>
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
              placeholder="Password"
              autoComplete="current-password"
              autoFocus
            />
            <button type="submit" className="vnc-login-go" disabled={pass === ""}>
              Connect
            </button>
          </form>
        )}
        {why && state === "closed" && (
          <div className="vnc-login">
            <div className="vnc-login-title">Not connected</div>
            <div className="vnc-login-hint">{why}</div>
            <button className="vnc-login-go" onClick={() => setAttempt((n) => n + 1)}>
              Try again
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
