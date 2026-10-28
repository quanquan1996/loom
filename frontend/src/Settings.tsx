import { Moon, Sun, X } from "lucide-react"
import { useEffect, type ReactNode } from "react"
import { createPortal } from "react-dom"
import type { AgentBackend } from "./api"
import type { Appearance, Settings } from "./settings"

/**
 * The gear at the foot of the sidebar: this device's appearance, and the
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

          <Row label="New sessions" hint="The agent + starts. A session keeps its agent for good.">
            <Segmented<AgentBackend>
              value={settings.backend}
              options={[
                ["claude_code", "Claude Code"],
                ["codex", "Codex"],
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
