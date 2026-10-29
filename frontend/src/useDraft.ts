import { useCallback, useEffect, useRef, useState } from "react"
import { getDraft, putDraft } from "./api"

/**
 * The composer's text for one session, kept on this device and on the server.
 *
 * This device's copy (localStorage) is there at once and offline, and says
 * whether it reached the server. The server's copy is what another device, or
 * this one after a reload, opens the session with. On opening, a copy that
 * never got through is pushed; otherwise the server's is taken, unless typing
 * here has begun since. While it is open, each write from anywhere arrives as
 * `remote` and is taken on the same terms. See `Loom.Agent.Draft`.
 */
const KEY = (id: string) => `loom_draft_${id}`

// How long typing has to pause before the draft goes to the server.
const SAVE_AFTER_MS = 800

type Local = { text: string; synced: boolean }

function loadLocal(id: string): Local | null {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY(id)) ?? "null")
    return raw && typeof raw.text === "string" ? { text: raw.text, synced: raw.synced === true } : null
  } catch {
    return null
  }
}

function saveLocal(id: string, local: Local) {
  try {
    if (local.text === "" && local.synced) localStorage.removeItem(KEY(id))
    else localStorage.setItem(KEY(id), JSON.stringify(local))
  } catch {
    // Full or disabled storage: the server's copy still has it.
  }
}

export function useDraft(id: string, remote: { id: string; text: string } | null): [string, (text: string) => void] {
  const [text, setText] = useState(() => loadLocal(id)?.text ?? "")
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const push = useCallback(
    (value: string, keepalive = false) => {
      if (timer.current) clearTimeout(timer.current)
      timer.current = null
      putDraft(id, value, keepalive).then(
        () => {
          // Only if nothing newer was typed while this was on its way.
          if (loadLocal(id)?.text === value) saveLocal(id, { text: value, synced: true })
        },
        () => {},
      )
    },
    [id],
  )

  // What the server has, when nothing here is newer.
  const pull = useCallback(() => {
    const local = loadLocal(id)
    if (local && !local.synced) return push(local.text)
    getDraft(id).then(
      ({ text: server }) => {
        const now = loadLocal(id)
        if (timer.current || (now && !now.synced)) return
        saveLocal(id, { text: server, synced: true })
        setText(server)
      },
      () => {},
    )
  }, [id, push])

  useEffect(() => {
    pull()
    // Back from another app or tab, where it may have changed on another
    // device; going away, whatever is pending goes now.
    const onVisibility = () => {
      if (document.visibilityState === "visible") return pull()
      const local = loadLocal(id)
      if (timer.current && local) push(local.text, true)
    }
    document.addEventListener("visibilitychange", onVisibility)
    // A save that failed offline goes once there is a network again.
    window.addEventListener("online", pull)
    return () => {
      document.removeEventListener("visibilitychange", onVisibility)
      window.removeEventListener("online", pull)
      // Leaving the session.
      const local = loadLocal(id)
      if (timer.current && local) push(local.text, true)
    }
  }, [id, pull, push])

  // Written somewhere — sent or cleared on another device, typed there, or
  // this device's own write coming back. Typing here that has not reached the
  // server yet is newer than any of them, and its own write follows.
  useEffect(() => {
    // Until the switch to another session settles, the last one's.
    if (remote?.id !== id) return
    const local = loadLocal(id)
    if (timer.current || (local && !local.synced)) return
    saveLocal(id, { text: remote.text, synced: true })
    setText(remote.text)
  }, [id, remote])

  const update = useCallback(
    (value: string) => {
      setText(value)
      saveLocal(id, { text: value, synced: false })
      if (timer.current) clearTimeout(timer.current)
      // Sent, or cleared: at once, so another device doesn't keep offering it.
      if (value === "") push(value)
      else timer.current = setTimeout(() => push(value), SAVE_AFTER_MS)
    },
    [id, push],
  )

  return [text, update]
}
