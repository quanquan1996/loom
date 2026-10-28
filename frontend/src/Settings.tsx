import { Moon, Sun, X } from "lucide-react"
import { useEffect, type ReactNode } from "react"
import { createPortal } from "react-dom"
import type { AgentBackend } from "./api"
import type { Appearance, Settings } from "./settings"
import { Slider } from "./Slider"

/**
 * The gear at the foot of the sidebar: this device's appearance and text sizes, and the
 * engine "+" starts a session on. Each choice takes effect as it is made;
 * there is nothing to save.
 */
export function SettingsDialog({
  settings,
  onChange,
  onClose,
}: {
  settings: Settings
  onChange: (patch: Partial<Settings>) => void
  onClose: () => void
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose()
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])

  return createPortal(
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal settings-dialog" role="dialog" aria-label="Settings">
        <div className="modal-head">
          <span>Settings</span>
          <button className="icon-btn" onClick={onClose} title="Close">
            <X />
          </button>
        </div>

        <div className="settings-body">
          <Row label="Appearance" hint="On this device.">
            <Segmented<Appearance>
              value={settings.appearance}
              options={[
                ["light", "Light", <Sun key="s" />],
                ["dark", "Dark", <Moon key="m" />],
              ]}
              onChange={(appearance) => onChange({ appearance })}
            />
          </Row>

          <TextSizes settings={settings} onChange={onChange} />

          <Row label="New sessions" hint="The agent + starts. A session keeps its agent for good.">
            <Segmented<AgentBackend>
              value={settings.backend}
              options={[
                ["claude_code", "Claude Code"],
                ["codex", "Codex"],
                ["kiro", "Kiro"],
              ]}
              onChange={(backend) => onChange({ backend })}
            />
          </Row>
        </div>
      </div>
    </div>,
    document.body,
  )
}

// The interface in px, as it is set; each area in percent of it.
const AREAS: { key: "sidebarScale" | "chatScale" | "codeScale"; label: string }[] = [
  { key: "sidebarScale", label: "Sidebar" },
  { key: "chatScale", label: "Messages" },
  { key: "codeScale", label: "Code" },
]

/**
 * Text size: the whole interface, then the sidebar, the conversation and its
 * code each on top of it. Sliders, applied as they move, so the page behind
 * the dialog is the preview.
 */
function TextSizes({
  settings,
  onChange,
}: {
  settings: Settings
  onChange: (patch: Partial<Settings>) => void
}) {
  const px = Math.round(16 * settings.fontScale)
  const changed =
    settings.fontScale !== 1 || AREAS.some(({ key }) => settings[key] !== 1)
  return (
    <div className="settings-row text-sizes">
      <div className="settings-text">
        <span className="settings-label">Text size</span>
        <span className="settings-hint">On this device.</span>
        {changed && (
          <button
            className="settings-reset"
            onClick={() => onChange({ fontScale: 1, sidebarScale: 1, chatScale: 1, codeScale: 1 })}
          >
            Reset
          </button>
        )}
      </div>
      <div className="size-rows">
        <div className="size-row">
          <span className="size-name">Interface</span>
          <Slider
            min={12}
            max={20}
            step={1}
            value={px}
            label="Interface text size"
            valueText={`${px}px`}
            onChange={(v) => onChange({ fontScale: v / 16 })}
          />
          <span className="size-value">{px}px</span>
        </div>
        {AREAS.map(({ key, label }) => {
          const pct = Math.round(settings[key] * 100)
          return (
            <div className="size-row" key={key}>
              <span className="size-name">{label}</span>
              <Slider
                min={80}
                max={140}
                step={5}
                value={pct}
                label={`${label} text size`}
                valueText={`${pct}%`}
                onChange={(v) => onChange({ [key]: v / 100 })}
              />
              <span className="size-value">{pct}%</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function Row({ label, hint, children }: { label: string; hint: string; children: ReactNode }) {
  return (
    <div className="settings-row">
      <div className="settings-text">
        <span className="settings-label">{label}</span>
        <span className="settings-hint">{hint}</span>
      </div>
      {children}
    </div>
  )
}

function Segmented<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T
  options: [T, string, ReactNode?][]
  onChange: (value: T) => void
}) {
  return (
    <div className="segmented" role="radiogroup">
      {options.map(([v, label, icon]) => (
        <button
          key={v}
          role="radio"
          aria-checked={v === value}
          className={v === value ? "on" : ""}
          onClick={() => onChange(v)}
        >
          {icon}
          {label}
        </button>
      ))}
    </div>
  )
}
