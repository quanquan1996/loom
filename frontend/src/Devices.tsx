import { ChevronRight, Monitor, X } from "lucide-react"
import { useEffect, useState } from "react"
import { createPortal } from "react-dom"
import { DEVICE_ICONS, DeviceIcon, ICON_LABELS, deviceIcon } from "./DeviceIcon"
import { isComposing } from "./ime"
import {
  androidInstall,
  createDevice,
  forwardOff,
  forwardOn,
  installCommands,
  renameDevice,
  type Device,
} from "./api"

/**
 * The user's machines that agents can reach through `loom-node` — add, rename,
 * remove, and get the command that installs one.
 *
 * Who is online comes from the lobby channel, so the dots change while the
 * dialog is open. The install command is shown once, right after it is made:
 * the code in it works one time, for a day, and the token it hands the
 * device exists nowhere else.
 */
export function DevicesDialog({
  devices,
  onUpsert,
  onOpenDesktop,
  onClose,
}: {
  devices: Device[]
  onUpsert: (device: Device) => void
  onOpenDesktop: (device: Device) => void
  onClose: () => void
}) {
  const [name, setName] = useState("")
  // The icon for the device being added; null follows the os it reports.
  const [icon, setIcon] = useState<Device["icon"]>(null)
  const [error, setError] = useState<string | null>(null)
  // The device whose install commands are on screen, and its code.
  const [install, setInstall] = useState<{ id: string; code: string } | null>(null)
  // The device whose settings are open.
  const [openId, setOpenId] = useState<string | null>(null)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose()
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])

  // Its install code has to come from the server, so this one waits — but
  // says so, and cannot be sent twice.
  const [adding, setAdding] = useState(false)
  const add = async () => {
    const value = name.trim()
    if (value === "" || adding) return
    setAdding(true)
    try {
      const { node, code } = await createDevice(value, icon)
      onUpsert(node)
      setName("")
      setIcon(null)
      setError(null)
      setInstall({ id: node.id, code })
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setAdding(false)
    }
  }

  const forward = async (device: Device, port: number | null) => {
    try {
      const { node } = port === null ? await forwardOff(device.id) : await forwardOn(device.id, port)
      onUpsert(node)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  // The new name shows on the tap; the old one comes back if refused.
  const rename = async (device: Device, value: string) => {
    onUpsert({ ...device, name: value })
    try {
      const { node } = await renameDevice(device.id, value)
      onUpsert(node)
      setError(null)
    } catch (e) {
      onUpsert(device)
      setError((e as Error).message)
    }
  }

  return createPortal(
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal devices" role="dialog" aria-label="Devices">
        <div className="modal-head">
          <span>Devices</span>
          <button className="icon-btn" onClick={onClose} title="Close">
            <X />
          </button>
        </div>

        <div className="device-list">
          {devices.length === 0 && (
            <div className="device-empty">
              No devices yet. Add your Mac, PC or a WSL box, run the command it
              gives you there, and agents can run commands on it.
            </div>
          )}
          {groupDevices(devices).map((g) => (
            <div key={g.label} className="device-group">
              <div className="device-group-label">{g.label}</div>
              {g.devices.map((d) => (
                <div key={d.id}>
                  <DeviceRow
                    device={d}
                    open={openId === d.id}
                    onToggle={() => setOpenId((id) => (id === d.id ? null : d.id))}
                    onRename={(value) => rename(d, value)}
                    onForward={(port) => forward(d, port)}
                    onVnc={() => onOpenDesktop(d)}
                  />
                  {install?.id === d.id && (
                    <InstallBox code={install.code} onDone={() => setInstall(null)} />
                  )}
                </div>
              ))}
            </div>
          ))}
        </div>

        {error && <div className="device-error">{error}</div>}

        <form
          className="device-add"
          onSubmit={(e) => {
            e.preventDefault()
            void add()
          }}
        >
          <IconPicker value={icon} onChange={setIcon} />
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="name, e.g. mac"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
          />
          <button type="submit" className="text-btn" disabled={name.trim() === "" || adding}>
            {adding ? "Adding…" : "Add"}
          </button>
        </form>
      </div>
    </div>,
    document.body,
  )
}

// Kinds in the order the list shows them; a device that has not said what it
// is comes last.
const KIND_ORDER = ["linux", "windows", "mac", "android", "bot"] as const
const kindRank = (d: Device) => {
  const i = deviceIcon(d)
  return i === null ? KIND_ORDER.length : KIND_ORDER.indexOf(i)
}

/**
 * Online devices grouped by kind (Linux, Windows, Mac, Android, Bot, Other),
 * then every offline one under "Offline" in the same kind order; by name
 * within a group.
 */
function groupDevices(devices: Device[]): { label: string; devices: Device[] }[] {
  const sorted = [...devices].sort((a, b) => kindRank(a) - kindRank(b) || a.name.localeCompare(b.name))
  const groups: { label: string; devices: Device[] }[] = []
  const push = (label: string, d: Device) => {
    const last = groups[groups.length - 1]
    if (last?.label === label) last.devices.push(d)
    else groups.push({ label, devices: [d] })
  }
  for (const d of sorted.filter((d) => d.online)) {
    const i = deviceIcon(d)
    push(i === null ? "Other" : ICON_LABELS[i], d)
  }
  for (const d of sorted.filter((d) => !d.online)) push("Offline", d)
  return groups
}

/**
 * The five marks to pick from when adding a device; tapping the chosen one
 * again unpicks it, so the icon follows the os. Once added it stays.
 */
function IconPicker({ value, onChange }: { value: Device["icon"]; onChange: (icon: Device["icon"]) => void }) {
  return (
    <div className="device-icons" role="radiogroup" aria-label="Icon">
      {DEVICE_ICONS.map((i) => (
        <button
          key={i}
          type="button"
          role="radio"
          aria-checked={value === i}
          className={"device-icon-pick" + (value === i ? " on" : "")}
          title={ICON_LABELS[i]}
          onClick={() => onChange(value === i ? null : i)}
        >
          <DeviceIcon icon={i} />
        </button>
      ))}
    </div>
  )
}

function DeviceRow({
  device,
  open,
  onToggle,
  onRename,
  onForward,
  onVnc,
}: {
  device: Device
  // Its settings are shown: one device at a time, opened by tapping its row.
  open: boolean
  onToggle: () => void
  onRename: (name: string) => void
  // A port to switch forwarding on to, or null for off.
  onForward: (port: number | null) => void
  onVnc: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(device.name)
  const [port, setPort] = useState(String(device.forward?.port ?? 5900))
  const portNumber = /^\d{1,5}$/.test(port) && +port >= 1 && +port <= 65535 ? +port : null

  const commit = () => {
    const value = draft.trim()
    if (value !== "" && value !== device.name) onRename(value)
    setEditing(false)
  }

  const system = device.os ? `${device.os}/${device.arch}` : null

  return (
    <div className={"device-item" + (open ? " open" : "")}>
      <div
        className="device"
        role="button"
        tabIndex={0}
        aria-expanded={open}
        onClick={() => !editing && onToggle()}
        onKeyDown={(e) => !editing && (e.key === "Enter" || e.key === " ") && (e.preventDefault(), onToggle())}
      >
        <span
          className={"dot" + (device.online ? " online" : "")}
          title={device.online ? "online" : "offline"}
        />
        <DeviceIcon icon={deviceIcon(device)} />
        <div className="device-body">
          {editing ? (
            <input
              className="device-name-input"
              value={draft}
              autoFocus
              onClick={(e) => e.stopPropagation()}
              onChange={(e) => setDraft(e.target.value)}
              onBlur={commit}
              onKeyDown={(e) => {
                e.stopPropagation()
                if (isComposing(e)) return
                if (e.key === "Enter") commit()
                if (e.key === "Escape") {
                  setDraft(device.name)
                  setEditing(false)
                }
              }}
            />
          ) : (
            <span className="device-name">{device.name}</span>
          )}
          <span className="device-meta">
            {[system, device.hostname, seen(device)].filter(Boolean).join(" · ")}
          </span>
        </div>
        {device.forward && device.online && (
          <button
            className="device-quick"
            title="Open its screen over VNC"
            aria-label={`Open ${device.name}'s screen`}
            onClick={(e) => {
              e.stopPropagation()
              onVnc()
            }}
          >
            <Monitor />
          </button>
        )}
        <ChevronRight className="device-chevron" />
      </div>

      {open && (
        <div className="device-panel">
          <div className="device-setting">
            <span className="device-setting-label">Port forwarding</span>
            <input
              className="device-port"
              value={device.forward ? String(device.forward.port) : port}
              disabled={!!device.forward}
              onChange={(e) => setPort(e.target.value.trim())}
              inputMode="numeric"
              aria-label="Port"
              title="A port on the device's own loopback; 5900 is VNC. Goes off after 30 idle minutes."
            />
            <button
              role="switch"
              aria-checked={!!device.forward}
              aria-label="Port forwarding"
              className={"switch" + (device.forward ? " on" : "")}
              disabled={!device.forward && portNumber === null}
              onClick={() => onForward(device.forward ? null : portNumber)}
            />
          </div>
          <button
            className="device-rename"
            onClick={() => {
              setDraft(device.name)
              setEditing(true)
            }}
          >
            Rename
          </button>
        </div>
      )}
    </div>
  )
}

function InstallBox({ code, onDone }: { code: string; onDone: () => void }) {
  const [copied, setCopied] = useState<string | null>(null)
  const [tab, setTab] = useState<"unix" | "windows" | "android">("unix")

  const copy = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(text)
    } catch {
      // No clipboard (an http origin): the text is selectable instead.
    }
  }

  const [unix, windows] = installCommands(code)
  const android = androidInstall(code)

  const tabs = [
    { key: "unix", label: "Mac · Linux" },
    { key: "windows", label: "Windows" },
    { key: "android", label: "Android" },
  ] as const

  // One copyable code/command block with its own Copy button.
  const block = (text: string) => (
    <>
      <div className="install-system">
        <span />
        <button className="text-btn" onClick={() => copy(text)}>
          {copied === text ? "Copied" : "Copy"}
        </button>
      </div>
      <code className="install-command" onClick={(e) => selectAll(e.currentTarget)}>
        {text}
      </code>
    </>
  )

  return (
    <div className="install-box">
      <div className="install-tabs">
        {tabs.map((t) => (
          <button
            key={t.key}
            className={`install-tab${tab === t.key ? " active" : ""}`}
            onClick={() => setTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "unix" && (
        <>
          <div className="install-hint">Run in a terminal — works once, within 2 minutes:</div>
          {block(unix.command)}
        </>
      )}

      {tab === "windows" && (
        <>
          <div className="install-hint">Run in PowerShell — works once, within 2 minutes:</div>
          {block(windows.command)}
        </>
      )}

      {tab === "android" && (
        <>
          <div className="install-hint">
            Install the{" "}
            <a href={android.appUrl} target="_blank" rel="noreferrer">
              Loom Node app
            </a>
            , open it, and enter this code:
          </div>
          {block(code)}
        </>
      )}

      <div className="install-actions">
        <button className="text-btn" onClick={onDone}>
          Done
        </button>
      </div>
    </div>
  )
}

function selectAll(el: HTMLElement) {
  const range = document.createRange()
  range.selectNodeContents(el)
  const selection = window.getSelection()
  selection?.removeAllRanges()
  selection?.addRange(range)
}

function seen(device: Device): string {
  if (device.online) return "online"
  if (!device.last_seen_at) return "never connected"
  const mins = Math.floor((Date.now() - Date.parse(device.last_seen_at)) / 60000)
  if (mins < 1) return "seen just now"
  if (mins < 60) return `seen ${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `seen ${hours}h ago`
  return `seen ${Math.floor(hours / 24)}d ago`
}
