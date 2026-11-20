import { useSyncExternalStore } from "react"
import { authHeaders, type AgentBackend } from "./api"

/**
 * Which agent CLIs this Loom offers and the one "+" starts a session on: the
 * server's `Loom.Backends`, one answer for every device. A switch only takes a
 * CLI out of the menus; nothing stops a session on one that is off. The last
 * answer is kept in localStorage so the menus are right before the fetch lands.
 */
export type Backends = {
  enabled: AgentBackend[]
  default: AgentBackend
  /** Those whose CLI the server found. */
  installed: AgentBackend[]
}

export const BACKENDS: { id: AgentBackend; label: string }[] = [
  { id: "claude_code", label: "Claude Code" },
  { id: "codex", label: "Codex" },
  { id: "kiro", label: "Kiro" },
  { id: "agy", label: "Antigravity" },
  { id: "codebuddy", label: "CodeBuddy" },
  { id: "grok", label: "Grok" },
]

const KEY = "loom_backends"
const ALL = BACKENDS.map((b) => b.id)

function cached(): Backends {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) ?? "null")
    if (saved && Array.isArray(saved.enabled) && saved.enabled.length) return saved
  } catch {
    // Unreadable: as if never fetched.
  }
  return { enabled: ALL, default: "claude_code", installed: ALL }
}

let state = cached()
const listeners = new Set<() => void>()

function set(next: Backends) {
  state = next
  localStorage.setItem(KEY, JSON.stringify(next))
  for (const l of listeners) l()
}

/** Fetch the server's answer. Quiet on failure: the cached one stands. */
export async function refreshBackends() {
  try {
    const res = await fetch("/api/backends", { headers: authHeaders() })
    if (res.ok) set(await res.json())
  } catch {
    // Offline: the cached answer stands.
  }
}

/** Save the switches and the default; shown at once, corrected by the reply. */
export async function saveBackends(enabled: AgentBackend[], def: AgentBackend) {
  set({ ...state, enabled, default: enabled.includes(def) ? def : enabled[0] })
  const res = await fetch("/api/backends", {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ enabled, default: def }),
  })
  if (res.ok) set(await res.json())
  else void refreshBackends()
}

export function useBackends(): Backends {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l)
      return () => listeners.delete(l)
    },
    () => state,
  )
}

/** The CLIs to list in a menu: those switched on, plus `keep` (a session's own). */
export function useOffered(keep?: string): { id: AgentBackend; label: string }[] {
  const { enabled } = useBackends()
  return BACKENDS.filter((b) => enabled.includes(b.id) || b.id === keep)
}
