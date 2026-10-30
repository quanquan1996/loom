import { X } from "lucide-react"
import { useEffect, useState } from "react"
import { createPortal } from "react-dom"
import { isComposing } from "./ime"
import {
  createDevice,
  deleteDevice,
  deviceInstallCode,
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
  onClose,
}: {
  devices: Device[]
  onUpsert: (device: Device) => void
  onClose: () => void
}) {
  const [name, setName] = useState("")
  const [error, setError] = useState<string | null>(null)
  // The device whose install commands are on screen, and its code.
  const [install, setInstall] = useState<{ id: string; code: string } | null>(null)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose()
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])

  const add = async () => {
    const value = name.trim()
    if (value === "") return
    try {
      const { node, code } = await createDevice(value)
      onUpsert(node)
      setName("")
      setError(null)
      setInstall({ id: node.id, code })
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const reinstall = async (device: Device) => {
    try {
      const { code } = await deviceInstallCode(device.id)
      setError(null)
      setInstall({ id: device.id, code })
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const remove = async (device: Device) => {
    if (!confirm(`Remove ${device.name}? loom-node uninstalls itself from it: right away if it is online, otherwise the next time it connects.`)) return
    try {
      await deleteDevice(device.id)
      if (install?.id === device.id) setInstall(null)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const rename = async (device: Device, value: string) => {
    try {
      const { node } = await renameDevice(device.id, value)
      onUpsert(node)
      setError(null)
    } catch (e) {
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
          {devices.map((d) => (
            <div key={d.id}>
              <DeviceRow
                device={d}
                onRename={(value) => rename(d, value)}
                onReinstall={() => reinstall(d)}
                onRemove={() => remove(d)}
              />
              {install?.id === d.id && (
                <InstallBox code={install.code} onDone={() => setInstall(null)} />
              )}
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
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="name, e.g. mac"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
          />
          <button type="submit" className="text-btn" disabled={name.trim() === ""}>
            Add
          </button>
        </form>
      </div>
    </div>,
    document.body,
  )
}

function DeviceRow({
  device,
  onRename,
  onReinstall,
  onRemove,
}: {
  device: Device
  onRename: (name: string) => void
  onReinstall: () => void
  onRemove: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(device.name)

  const commit = () => {
    const value = draft.trim()
    if (value !== "" && value !== device.name) onRename(value)
    setEditing(false)
  }

  const system = device.os ? `${device.os}/${device.arch}` : null

  return (
    <div className="device">
      <span
        className={"dot" + (device.online ? " online" : "")}
        title={device.online ? "online" : "offline"}
      />
      <div className="device-body">
        {editing ? (
          <input
            className="device-name-input"
            value={draft}
            autoFocus
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commit}
            onKeyDown={(e) => {
              if (isComposing(e)) return
              if (e.key === "Enter") commit()
              if (e.key === "Escape") {
                setDraft(device.name)
                setEditing(false)
              }
            }}
          />
        ) : (
          <span
            className="device-name"
            title="Double-click to rename"
            onDoubleClick={() => {
              setDraft(device.name)
              setEditing(true)
            }}
          >
            {device.name}
          </span>
        )}
        <span className="device-meta">
          {[system, device.hostname, seen(device)].filter(Boolean).join(" · ")}
        </span>
      </div>
      <button className="device-action" onClick={onReinstall} title="New install command (replaces this device's token)">
        install
      </button>
      <button className="session-del device-del" onClick={onRemove} title="Remove device">
        <X />
      </button>
    </div>
  )
}

function InstallBox({ code, onDone }: { code: string; onDone: () => void }) {
  const [copied, setCopied] = useState<string | null>(null)

  const copy = async (command: string) => {
    try {
      await navigator.clipboard.writeText(command)
      setCopied(command)
    } catch {
      // No clipboard (an http origin): the text is selectable instead.
    }
  }

  return (
    <div className="install-box">
      <div className="install-hint">Run one of these in a terminal on the device — it works once, within a day:</div>
      {installCommands(code).map(({ system, command }) => (
        <div key={system} className="install-option">
          <div className="install-system">
            <span>{system}</span>
            <button className="text-btn" onClick={() => copy(command)}>
              {copied === command ? "Copied" : "Copy"}
            </button>
          </div>
          <code className="install-command" onClick={(e) => selectAll(e.currentTarget)}>
            {command}
          </code>
        </div>
      ))}
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
