import { ArchiveRestore, ChevronDown, ChevronRight, Moon, Sun, X } from "lucide-react"
import { useEffect, useState, type ReactNode } from "react"
import { createPortal } from "react-dom"
import type { AgentBackend, AgentInfo, Project } from "./api"
import type { Appearance, Settings } from "./settings"
import { Slider } from "./Slider"
import { BossProfile } from "./Boss"

/**
 * The gear at the foot of the sidebar: this device's appearance and text sizes, the
 * engine "+" starts a session on, the boss profile the employees share, and
 * the archived sessions. Each choice takes
 * effect as it is made; there is nothing to save.
 */
export function SettingsDialog({
  settings,
  onChange,
  onClose,
  archived,
  projects,
  onOpen,
  onUnarchive,
}: {
  settings: Settings
  onChange: (patch: Partial<Settings>) => void
  onClose: () => void
  archived: AgentInfo[]
  projects: Project[]
  onOpen: (id: string) => void
  onUnarchive: (id: string) => Promise<void>
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

          <BossProfile />

          <Archived sessions={archived} projects={projects} onOpen={onOpen} onUnarchive={onUnarchive} />
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

/**
 * The archived sessions: out of the sidebar's lists, nothing else changed.
 * Folded; open, a row each — tap to open it, or bring it back.
 */
function Archived({
  sessions,
  projects,
  onOpen,
  onUnarchive,
}: {
  sessions: AgentInfo[]
  projects: Project[]
  onOpen: (id: string) => void
  onUnarchive: (id: string) => Promise<void>
}) {
  const [open, setOpen] = useState(false)
  const name = (id?: string | null) => (id ? (projects.find((p) => p.id === id)?.name ?? "") : "")
  return (
    <div className="settings-row archived">
      <button className="settings-text archived-head" onClick={() => setOpen((o) => !o)} disabled={!sessions.length}>
        <span className="settings-label">Archived</span>
        <span className="settings-hint">
          {sessions.length ? `${sessions.length}, hidden from the lists. Writing in one brings it back.` : "None."}
        </span>
        {sessions.length > 0 && (open ? <ChevronDown className="archived-fold" /> : <ChevronRight className="archived-fold" />)}
      </button>
      {open && sessions.length > 0 && (
        <div className="archived-list">
          {sessions.map((s) => (
            <div className="archived-item" key={s.id}>
              <button className="archived-open" onClick={() => onOpen(s.id)}>
                <span className="archived-title">{s.title || "Untitled"}</span>
                {s.project_id && <span className="archived-project">{name(s.project_id)}</span>}
              </button>
              <button className="icon-btn" title="Unarchive" onClick={() => void onUnarchive(s.id)}>
                <ArchiveRestore />
              </button>
            </div>
          ))}
        </div>
      )}
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
