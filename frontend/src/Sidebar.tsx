import {
  Bell,
  BellOff,
  ChevronRight,
  Clock,
  Folder,
  FolderOpen,
  FolderPlus,
  Globe,
  Keyboard,
  KeyboardOff,
  MonitorSmartphone,
  MoreHorizontal,
  PanelLeftClose,
  Pin,
  Plus,
  Settings,
} from "lucide-react"
import { useEffect, useState } from "react"
import type { AgentBackend, AgentInfo, Device, Project } from "./api"
import { RenameInput } from "./Confirm"
import { DevicesDialog } from "./Devices"
import { SessionMenu } from "./SessionMenu"
import { backendShort } from "./format"
import type { Push } from "./push"
import { lastActive } from "./useLobby"

/**
 * Which parts of the sidebar are not as they start, by key: `toggled` in App.
 * Sessions and Pinned start open, Projects and each project start folded, so
 * a key in the set means the opposite of that.
 */
export const PROJECTS_SECTION = "section:projects"
export const SESSIONS_SECTION = "section:sessions"
export const PINNED_SECTION = "section:pinned"

export const isOpen = (toggled: Set<string>, key: string) =>
  key === SESSIONS_SECTION || key === PINNED_SECTION ? !toggled.has(key) : toggled.has(key)

/**
 * The sidebar's lists, which overlap on purpose: each project (most recently
 * used first) with all its sessions; then the pinned sessions; then the rest,
 * most recently active first. A session put in a project stays in the list it
 * was found in.
 */
export function sidebarGroups(sessions: AgentInfo[], projects: Project[]) {
  const inside = new Map<string, AgentInfo[]>(projects.map((p) => [p.id, []]))
  for (const s of sessions) if (s.project_id) inside.get(s.project_id)?.push(s)
  const used = (p: Project) => {
    const first = inside.get(p.id)![0]
    return first ? lastActive(first) : p.created_at
  }
  const groups = [...projects]
    .sort((a, b) => used(b) - used(a))
    .map((project) => ({ project, sessions: inside.get(project.id)! }))
  return { groups, pinned: sessions.filter((s) => s.pinned), recent: sessions.filter((s) => !s.pinned) }
}

/** What j/k walks: every session row that is showing, each once, top to bottom. */
export function sidebarOrder(sessions: AgentInfo[], projects: Project[], toggled: Set<string>): AgentInfo[] {
  const { groups, pinned, recent } = sidebarGroups(sessions, projects)
  const rows = [
    ...(isOpen(toggled, PROJECTS_SECTION)
      ? groups.flatMap((g) => (isOpen(toggled, g.project.id) ? g.sessions : []))
      : []),
    ...(isOpen(toggled, PINNED_SECTION) ? pinned : []),
    ...(isOpen(toggled, SESSIONS_SECTION) ? recent : []),
  ]
  return rows.filter((s, i) => rows.findIndex((r) => r.id === s.id) === i)
}

type Props = {
  sessions: AgentInfo[]
  projects: Project[]
  // What is folded or unfolded against its default; see `isOpen`.
  toggled: Set<string>
  onToggle: (key: string) => void
  // A project to edit, or null to make one.
  onEditProject: (project: Project | null) => void
  // The Tasks page, and whether it is the one showing.
  tasksOpen: boolean
  onOpenTasks: () => void
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
  // From a row's menu: put its name up for editing, pin it, move it.
  onRename: (id: string) => void
  onPin: (id: string, pinned: boolean) => Promise<void>
  onMove: (id: string, projectId: string | null) => Promise<void>
  onCollapse: () => void
  browserOpen: boolean
  onToggleBrowser: () => void
  // What "+" starts, with no menu to choose from; see Settings.
  defaultBackend: AgentBackend
  onOpenSettings: () => void
}

export function Sidebar({
  sessions,
  projects,
  toggled,
  onToggle,
  onEditProject,
  tasksOpen,
  onOpenTasks,
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
  onRename,
  onPin,
  onMove,
  onCollapse,
  browserOpen,
  onToggleBrowser,
  defaultBackend,
  onOpenSettings,
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
  const { groups, pinned, recent } = sidebarGroups(sessions, projects)
  const open = (key: string) => isOpen(toggled, key)
  // The row whose menu is open, and where its button is.
  const [menu, setMenu] = useState<{ id: string; anchor: DOMRect } | null>(null)
  const menuFor = menu && sessions.find((s) => s.id === menu.id)
  const projectName = (s: AgentInfo) => projects.find((p) => p.id === s.project_id)?.name

  const row = (s: AgentInfo, nested: boolean) => (
    <div
      key={s.id}
      ref={s.id === cursorId ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
      className={
        "session" +
        (nested ? " nested" : "") +
        (menu?.id === s.id ? " menu-open" : "") +
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
      {/* Outside its project, which one it is in; under it, that goes without saying. */}
      {!nested && projectName(s) && (
        <span className="session-project" title={`in ${projectName(s)}`}>
          <Folder />
        </span>
      )}
      {nested && s.pinned && <Pin className="session-pin" />}
      <button
        className="session-del session-more"
        title="Rename, pin, move to a project, delete"
        onClick={(e) => {
          e.stopPropagation()
          const anchor = e.currentTarget.getBoundingClientRect()
          setMenu((m) => (m?.id === s.id ? null : { id: s.id, anchor }))
        }}
      >
        <MoreHorizontal />
      </button>
    </div>
  )

  return (
    <aside className="sidebar">
      <div className="sidebar-head">
        <span className="brand">loom</span>
        <span className="sidebar-actions">
          <NewSessionButton backend={defaultBackend} onCreate={(backend) => onCreate(backend)} />
          <button className="icon-btn" onClick={onCollapse} title="Hide sidebar">
            <PanelLeftClose />
          </button>
        </span>
      </div>

      <div className="session-list">
        {/* A top-level entry, like the sidebar's others: folded until asked. */}
        <div
          className={"nav-item" + (open(PROJECTS_SECTION) ? " open" : "")}
          role="button"
          aria-expanded={open(PROJECTS_SECTION)}
          onClick={() => onToggle(PROJECTS_SECTION)}
        >
          <Folder className="nav-icon" />
          <span className="nav-label">Projects</span>
          {projects.length > 0 && <span className="nav-count">{projects.length}</span>}
          <span className="nav-actions" onClick={(e) => e.stopPropagation()}>
            <button className="session-del nav-btn" onClick={() => onEditProject(null)} title="New project">
              <FolderPlus />
            </button>
          </span>
          <ChevronRight className="nav-chevron" />
        </div>
        {open(PROJECTS_SECTION) && (
          <div className="nav-children">
            {groups.length === 0 && (
              <button className="project-row project-new-row" onClick={() => onEditProject(null)}>
                <FolderPlus className="project-icon" />
                <span className="session-label">New project</span>
              </button>
            )}
            {groups.map(({ project, sessions: inside }) => {
              const unfolded = open(project.id)
              return (
                <div key={project.id} className={"project-group" + (unfolded ? " open" : "")}>
                  <div
                    className={"project-row" + (inside.some((s) => s.id === activeId) ? " holds-active" : "")}
                    onClick={() => onToggle(project.id)}
                    title={project.workspace}
                  >
                    {unfolded ? <FolderOpen className="project-icon" /> : <Folder className="project-icon" />}
                    <span className="session-label">{project.name}</span>
                    <span className="project-actions" onClick={(e) => e.stopPropagation()}>
                      <NewSessionButton
                        backend={defaultBackend}
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
                    {inside.length > 0 && <span className="nav-count">{inside.length}</span>}
                  </div>
                  {unfolded && (
                    <div className="project-sessions">
                      {inside.length ? (
                        inside.map((s) => row(s, true))
                      ) : (
                        <div className="project-empty">No sessions yet.</div>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}

        {/* Another top-level entry: a page of its own, not a list. */}
        <div className={"nav-item" + (tasksOpen ? " current" : "")} role="button" onClick={onOpenTasks}>
          <Clock className="nav-icon" />
          <span className="nav-label">Tasks</span>
        </div>

        {pinned.length > 0 && (
          <>
            <Heading label="Pinned" open={open(PINNED_SECTION)} onToggle={() => onToggle(PINNED_SECTION)} />
            {open(PINNED_SECTION) && pinned.map((s) => row(s, false))}
          </>
        )}

        <Heading label="Recents" open={open(SESSIONS_SECTION)} onToggle={() => onToggle(SESSIONS_SECTION)} />
        {open(SESSIONS_SECTION) &&
          (recent.length ? (
            recent.map((s) => row(s, false))
          ) : (
            <div className="session-empty">{pinned.length ? "Nothing else yet." : "No sessions yet."}</div>
          ))}
      </div>

      {menu && menuFor && (
        <SessionMenu
          session={menuFor}
          projects={projects}
          anchor={menu.anchor}
          onRename={() => onRename(menuFor.id)}
          onPin={(on) => onPin(menuFor.id, on)}
          onMove={(projectId) => onMove(menuFor.id, projectId)}
          onDelete={() => onDelete(menuFor.id)}
          onClose={() => setMenu(null)}
        />
      )}

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
        {/* This device's preferences: appearance, and the agent "+" starts. */}
        <button className="devices-btn push-btn" onClick={onOpenSettings} title="Settings">
          <Settings />
          <span>Settings</span>
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

/** A list's heading, ChatGPT's "Pinned" and "Recent": bold, and it folds. */
function Heading({ label, open, onToggle }: { label: string; open: boolean; onToggle: () => void }) {
  return (
    <button className={"list-heading" + (open ? " open" : "")} onClick={onToggle} aria-expanded={open}>
      {label}
      <ChevronRight />
    </button>
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
 * "+": a new session on the default agent, at once. The agent is a setting
 * (Claude Code unless changed) rather than a question asked every time; a
 * session keeps the one it started on.
 */
function NewSessionButton({
  backend,
  onCreate,
  small = false,
  title = "New session",
}: {
  backend: AgentBackend
  onCreate: (backend: AgentBackend) => void
  // The one on a project's row, the size of the row's other buttons.
  small?: boolean
  title?: string
}) {
  return (
    <button
      className={small ? "session-del project-new" : "icon-btn"}
      onClick={() => onCreate(backend)}
      title={title}
    >
      <Plus />
    </button>
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
