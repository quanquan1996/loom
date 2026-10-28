import { useEffect, useState } from "react"
import type { AgentBackend } from "./api"

/**
 * This device's preferences, from the Settings dialog: how Loom looks, and
 * how big its text is, and which engine a new session starts on. Kept in localStorage — a phone and a
 * laptop may well want different ones — and applied as soon as they change.
 */
export type Appearance = "dark" | "light"

// Text size, as a multiple of the default (16px). Every size is in rem, so
// this one number scales the whole interface; see theme.css.
export const FONT_SCALES = [0.8125, 0.875, 0.9375, 1, 1.0625] as const
export type FontScale = (typeof FONT_SCALES)[number]

export type Settings = {
  appearance: Appearance
  fontScale: FontScale
  // What "+" makes, with nothing to choose. Codex is a setting away.
  backend: AgentBackend
}

const KEY = "loom_settings"
const DEFAULTS: Settings = { appearance: "dark", fontScale: 1, backend: "claude_code" }

function load(): Settings {
  try {
    return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") }
  } catch {
    return DEFAULTS
  }
}

// The status bar and a home-screen app's chrome follow the page: black on a
// phone and #212121 on a desktop when dark (see index.html), white when light.
function apply({ appearance, fontScale }: Settings) {
  document.documentElement.dataset.theme = appearance
  document.documentElement.style.setProperty("--font-scale", String(fontScale))
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
