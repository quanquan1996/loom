import { useEffect, useState } from "react"
import type { AgentBackend } from "./api"

/**
 * This device's preferences, from the Settings dialog: how Loom looks, and
 * which engine a new session starts on. Kept in localStorage — a phone and a
 * laptop may well want different ones — and applied as soon as they change.
 */
export type Appearance = "dark" | "light"

export type Settings = {
  appearance: Appearance
  // What "+" makes, with nothing to choose. Codex is a setting away.
  backend: AgentBackend
}

const KEY = "loom_settings"
const DEFAULTS: Settings = { appearance: "dark", backend: "claude_code" }

function load(): Settings {
  try {
    return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") }
  } catch {
    return DEFAULTS
  }
}

// The status bar and a home-screen app's chrome follow the page: black on a
// phone and #212121 on a desktop when dark (see index.html), white when light.
function apply({ appearance }: Settings) {
  document.documentElement.dataset.theme = appearance
  for (const meta of document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]')) {
    meta.dataset.dark ??= meta.content
    meta.content = appearance === "light" ? "#ffffff" : meta.dataset.dark
  }
}

// Before the first render, so a light page never flashes dark.
apply(load())

export function useSettings(): [Settings, (patch: Partial<Settings>) => void] {
  const [settings, setSettings] = useState(load)
  useEffect(() => {
    localStorage.setItem(KEY, JSON.stringify(settings))
    apply(settings)
  }, [settings])
  return [settings, (patch) => setSettings((s) => ({ ...s, ...patch }))]
}
