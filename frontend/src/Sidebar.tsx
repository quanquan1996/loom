import {
  Bell,
  BellOff,
  ChevronDown,
  ChevronRight,
  Folder,
  FolderOpen,
  FolderPlus,
  Globe,
  Keyboard,
  KeyboardOff,
  MonitorSmartphone,
  PanelLeftClose,
  Plus,
  Settings,
  X,
} from "lucide-react"
import { useEffect, useRef, useState } from "react"
import type { AgentBackend, AgentInfo, Device, Project } from "./api"
import { RenameInput } from "./Confirm"
import { DevicesDialog } from "./Devices"
import { backendShort } from "./format"
import type { Push } from "./push"
import { lastActive } from "./useLobby"

/**
 * The sidebar's rows top to bottom: each project (most recently used first)
 * with its sessions, then the sessions outside any project.
 */
export function sidebarGroups(sessions: AgentInfo[], projects: Project[]) {
  const known = new Set(projects.map((p) => p.id))
  const inside = new Map<string, AgentInfo[]>(projects.map((p) => [p.id, []]))
  const loose: AgentInfo[] = []
  // `sessions` is already most recent first, and keeps that order in a group.
  for (const s of sessions) {
    if (s.project_id && known.has(s.project_id)) inside.get(s.project_id)!.push(s)
    else loose.push(s)
  }
  const used = (p: Project) => {
    const first = inside.get(p.id)![0]
    return first ? lastActive(first) : p.created_at
  }
  const groups = [...projects]
    .sort((a, b) => used(b) - used(a))
    .map((project) => ({ project, sessions: inside.get(project.id)! }))
  return { groups, loose }
}

/** The sessions as drawn, folded projects left out: what j/k walks. */
export function sidebarOrder(sessions: AgentInfo[], projects: Project[], folded: Set<string>): AgentInfo[] {
  const { groups, loose } = sidebarGroups(sessions, projects)
  return [...groups.flatMap((g) => (folded.has(g.project.id) ? [] : g.sessions)), ...loose]
}

type Props = {
  sessions: AgentInfo[]
  projects: Project[]
  // Projects whose sessions are hidden, by id; see App.
  folded: Set<string>
  onFold: (projectId: string) => void
  // A project to edit, or null to make one.
  onEditProject: (project: Project | null) => void
  devices: Device[]
  onUpsertDevice: (device: Device) => void
  push: Push
  // Desktop only, so null on a phone; see keys.tsx.
  vim: { on: boolean; toggle: () => void } | null
  activeId: string | null
  // The session under the keyboard's cursor while the list is walked; see App.
  cursorId: string | null
  // The session whose name is being edited in its row, and where it goes.
  renamingId: string | null
  onRenamed: (id: string, title: string | null) => Promise<void>
  onSelect: (id: string) => void
  onCreate: (backend: AgentBackend, projectId?: string) => void
  onDelete: (id: string) => void
  onCollapse: () => void
  browserOpen: boolean
  onToggleBrowser: () => void
}

export function Sidebar({
  sessions,
  projects,
  folded,
  onFold,
  onEditProject,
  devices,
  onUpsertDevice,
  push,
  vim,
  activeId,
  cursorId,
  renamingId,
  onRenamed,
  onSelect,
  onCreate,
  onDelete,
  onCollapse,
  browserOpen,
  onToggleBrowser,
}: Props) {
  // Ages are relative, so they go stale without any new data. A local clock,
  // not a poll: nothing is fetched.
  const [, setNow] = useState(0)
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(timer)
  }, [])
  const [devicesOpen, setDevicesOpen] = useState(false)
  const online = devices.filter((d) => d.online).length
  const { groups, loose } = sidebarGroups(sessions, projects)

  const row = (s: AgentInfo, nested: boolean) => (
    <div
      key={s.id}
      ref={s.id === cursorId ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
      className={
        "session" +
        (nested ? " nested" : "") +
        (s.id === activeId ? " active" : "") +
        (s.id === cursorId ? " cursor" : "")
      }
      onClick={() => onSelect(s.id)}
    >
      <span className={"dot " + s.status} title={s.status} />
      {s.id === renamingId ? (
        <RenameInput value={s.title ?? s.id} stem={false} onDone={(title) => onRenamed(s.id, title)} />
      ) : (
        <span className="session-label">{s.title ?? s.id}</span>
      )}
      {s.queued > 0 && (
        <span className="session-queued" title="queued messages">
          {s.queued}
        </span>
      )}
      <span className="session-when" title={"last active " + new Date(lastActive(s)).toLocaleString()}>
        {when(lastActive(s))}
      </span>
      {/* Which engine is running it is not a detail: the two behave
          differently and the binding is permanent. */}
      <span className={"session-backend " + s.backend}>{backendShort(s.backend)}</span>
      <button
        className="session-del"
        title="Delete session and its history"
        onClick={(e) => {
          e.stopPropagation()
          onDelete(s.id)
        }}
      >
        <X />
      </button>
    </div>
  )

  return (
    <aside className="sidebar">
      <div className="sidebar-head">
        <span className="brand">loom</span>
        <span className="sidebar-actions">
          <button className="icon-btn" onClick={() => onEditProject(null)} title="New project">
            <FolderPlus />
          </button>
          <NewSessionButton onCreate={(backend) => onCreate(backend)} />
          <button className="icon-btn" onClick={onCollapse} title="Hide sidebar">
            <PanelLeftClose />
          </button>
        </span>
      </div>

      <div className="session-list">
        {sessions.length === 0 && projects.length === 0 && (
          <div className="session-empty">No sessions yet.</div>
        )}

        {groups.length > 0 && <div className="sidebar-section">Projects</div>}
        {groups.map(({ project, sessions: inside }) => {
          const open = !folded.has(project.id)
          const holdsActive = inside.some((s) => s.id === activeId)
          return (
            <div key={project.id} className="project-group">
              <div
                className={"project-row" + (!open && holdsActive ? " active" : "")}
                onClick={() => onFold(project.id)}
                title={project.workspace}
              >
                <span className="project-fold">{open ? <ChevronDown /> : <ChevronRight />}</span>
                {open ? <FolderOpen className="project-icon" /> : <Folder className="project-icon" />}
                <span className="session-label">{project.name}</span>
                {!open && inside.length > 0 && <span className="session-when">{inside.length}</span>}
                <span className="project-actions" onClick={(e) => e.stopPropagation()}>
                  <NewSessionButton
                    small
                    title={`New session in ${project.name}`}
                    onCreate={(backend) => onCreate(backend, project.id)}
                  />
                  <button
                    className="session-del project-edit"
                    title="Project settings"
                    onClick={() => onEditProject(project)}
                  >
                    <Settings />
                  </button>
                </span>
              </div>
              {open &&
                (inside.length ? (
                  inside.map((s) => row(s, true))
                ) : (
                  <div className="project-empty">No sessions yet.</div>
                ))}
            </div>
          )
        })}

        {groups.length > 0 && loose.length > 0 && <div className="sidebar-section">Sessions</div>}
        {loose.map((s) => row(s, false))}
      </div>

      <div className="sidebar-foot">
        {vim && (
          <button
            className={"devices-btn push-btn" + (vim.on ? " on" : "")}
            onClick={vim.toggle}
            title={vim.on ? "Vim mode is on; ? lists the keys. Click to turn it off." : "Turn on Vim mode: keys for the panes, ? lists them"}
          >
            {vim.on ? <Keyboard /> : <KeyboardOff />}
            <span>Vim mode</span>
            <span className="devices-count">{vim.on ? "on" : "off"}</span>
          </button>
        )}

        <PushButton push={push} />

        {/* Loom's own browser, the one agents drive: taking it over is how a
            site gets logged in to once and stays logged in. */}
        <button
          className={"devices-btn push-btn" + (browserOpen ? " on" : "")}
          onClick={onToggleBrowser}
          title="Loom's browser: log in to a site, or get past a check for the agents"
        >
          <Globe />
          <span>Browser</span>
          <span className="devices-count">{browserOpen ? "open" : ""}</span>
        </button>

        {/* The user's own machines, reachable by agents through loom-node. */}
        <button
          className={"devices-btn push-btn" + (online > 0 ? " on" : "")}
          onClick={() => setDevicesOpen(true)}
          title="Devices"
        >
          {/* An icon like the two above, so the labels line up; lit while any is online. */}
          <MonitorSmartphone />
          <span>Devices</span>
          <span className="devices-count">
            {online}/{devices.length}
          </span>
        </button>
        {devicesOpen && (
          <DevicesDialog
            devices={devices}
            onUpsert={onUpsertDevice}
            onClose={() => setDevicesOpen(false)}
          />
        )}
      </div>
    </aside>
  )
}

const PUSH_HINT: Record<Push["state"], string> = {
  on: "This device is notified when a turn ends. Click to stop.",
  off: "Get a notification on this device when a turn ends",
  denied: "Notifications are blocked for this site in the browser's settings",
  unsupported: "On an iPhone, add Loom to the Home Screen and open it from there to get notifications",
}

/** Notifications for this device, on or off; see `usePush`. */
function PushButton({ push }: { push: Push }) {
  const on = push.state === "on"
  const Icon = on ? Bell : BellOff
  return (
    <button
      className={"devices-btn push-btn" + (on ? " on" : "")}
      onClick={push.toggle}
      disabled={push.busy || push.state === "denied" || push.state === "unsupported"}
      title={push.error ?? PUSH_HINT[push.state]}
    >
      <Icon />
      <span>Notifications</span>
      <span className="devices-count">
        {push.error ? "failed" : push.busy ? "…" : on ? "on" : push.state === "off" ? "off" : "n/a"}
      </span>
    </button>
  )
}

/**
 * Creating a session means choosing an engine, so there is no plain "+".
 *
 * The choice cannot be changed later — the conversation lives in that engine's
 * own store — so it is made explicitly rather than defaulted.
 */
function NewSessionButton({
  onCreate,
  small = false,
  title = "New session",
}: {
  onCreate: (backend: AgentBackend) => void
  // The one on a project's row, the size of the row's other buttons.
  small?: boolean
  title?: string
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!open) return
    const onAway = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener("mousedown", onAway)
    return () => document.removeEventListener("mousedown", onAway)
  }, [open])

  const choose = (backend: AgentBackend) => {
    setOpen(false)
    onCreate(backend)
  }

  return (
    <span className="new-session" ref={ref}>
      <button
        className={small ? "session-del project-new" : "icon-btn"}
        onClick={() => setOpen((v) => !v)}
        title={title}
      >
        <Plus />
      </button>
      {open && (
        <div className="backend-menu">
          <button onClick={() => choose("claude_code")}>Claude Code</button>
          <button onClick={() => choose("codex")}>Codex</button>
        </div>
      )}
    </span>
  )
}

function when(ms: number): string {
  const mins = Math.floor((Date.now() - ms) / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return `${mins}m`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}
