import { ChevronDown, ChevronRight, Plus, Trash2 } from "lucide-react"
import { useEffect, useState } from "react"
import { addBossLine, bossProfile, deleteBossLine, updateBossLine, type BossLine } from "./api"
import { isComposing } from "./ime"
import "./Boss.css"

/**
 * The boss profile (`Loom.Employees`) in Settings: what every employee knows
 * about the user, a sentence a line, with who heard it and when. Employees
 * add to it when the user tells them something about themselves; here it is
 * only looked over. Folded like Archived; open, tap a line to change or
 * delete it, or add one at the foot.
 */
export function BossProfile() {
  const [lines, setLines] = useState<BossLine[] | null>(null)
  const [open, setOpen] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [editing, setEditing] = useState<string | null>(null)

  const act = async (call: Promise<BossLine[]>) => {
    try {
      setLines(await call)
      setError(null)
      return true
    } catch (e) {
      setError((e as Error).message)
      return false
    }
  }

  useEffect(() => {
    void act(bossProfile())
  }, [])

  return (
    <div className="settings-row archived">
      <button className="settings-text archived-head" onClick={() => setOpen((o) => !o)}>
        <span className="settings-label">Boss profile</span>
        <span className="settings-hint">
          What every employee knows about you{lines ? `: ${lines.length} ${lines.length === 1 ? "line" : "lines"}` : ""}.
        </span>
        {open ? <ChevronDown className="archived-fold" /> : <ChevronRight className="archived-fold" />}
      </button>
      {open && (
        <div className="boss-list">
          {error && <div className="boss-error">{error}</div>}
          {lines?.map((line) =>
            editing === line.id ? (
              <EditLine
                key={line.id}
                line={line}
                onSave={async (text) => {
                  if (text === line.text || (await act(updateBossLine(line.id, text)))) setEditing(null)
                }}
                onDelete={async () => {
                  if (await act(deleteBossLine(line.id))) setEditing(null)
                }}
                onCancel={() => setEditing(null)}
              />
            ) : (
              <button key={line.id} className="boss-line" onClick={() => setEditing(line.id)}>
                <span className="boss-text">{line.text}</span>
                <span className="boss-meta">
                  {day(line.at)} · {line.by_name ? `told ${line.by_name}` : "you wrote it"}
                </span>
              </button>
            ),
          )}
          <AddLine onAdd={(text) => act(addBossLine(text))} />
        </div>
      )}
    </div>
  )
}

function EditLine({
  line,
  onSave,
  onDelete,
  onCancel,
}: {
  line: BossLine
  onSave: (text: string) => Promise<void>
  onDelete: () => Promise<void>
  onCancel: () => void
}) {
  const [text, setText] = useState(line.text)
  return (
    <div className="boss-line editing">
      <textarea
        autoFocus
        rows={2}
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (isComposing(e)) return
          if (e.key === "Enter" && !e.shiftKey && text.trim()) {
            e.preventDefault()
            void onSave(text.trim())
          }
          if (e.key === "Escape") {
            e.stopPropagation()
            onCancel()
          }
        }}
      />
      <div className="boss-actions">
        <button className="boss-delete" onClick={onDelete} title="Delete this line">
          <Trash2 /> Delete
        </button>
        <span className="boss-spacer" />
        <button className="boss-button" onClick={onCancel}>
          Cancel
        </button>
        <button className="boss-button strong" disabled={!text.trim()} onClick={() => onSave(text.trim())}>
          Save
        </button>
      </div>
    </div>
  )
}

/** A line of its own, added on Enter. */
function AddLine({ onAdd }: { onAdd: (text: string) => Promise<boolean> }) {
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)

  const send = async () => {
    const value = text.trim()
    if (!value || busy) return
    setBusy(true)
    if (await onAdd(value)) setText("")
    setBusy(false)
  }

  return (
    <div className="boss-add">
      <input
        value={text}
        placeholder="Add a line"
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (isComposing(e)) return
          if (e.key === "Enter") {
            e.preventDefault()
            void send()
          }
        }}
      />
      <button className="icon-btn" onClick={send} disabled={!text.trim() || busy} title="Add">
        <Plus />
      </button>
    </div>
  )
}

// "10-29", as the employees are told it.
function day(ms: number) {
  const d = new Date(ms)
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
}
