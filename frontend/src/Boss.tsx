import { ArrowUp, Loader2, PanelLeft, Trash2 } from "lucide-react"
import { useEffect, useRef, useState } from "react"
import { addBossLine, bossProfile, deleteBossLine, updateBossLine, type BossLine } from "./api"
import { isComposing } from "./ime"
import "./Tasks.css"
import "./Boss.css"

/**
 * The boss profile (`Loom.Employees`): what every employee knows about the
 * user, a sentence a line, with who heard it and when. Employees add to it
 * when the user tells them something about themselves, and it applies at
 * once; the user edits or deletes a line by tapping it, and adds one below.
 * Laid out as the Tasks page is.
 */
export function BossProfile({
  showSidebarButton,
  onToggleSidebar,
}: {
  showSidebarButton: boolean
  onToggleSidebar: () => void
}) {
  const [lines, setLines] = useState<BossLine[] | null>(null)
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
    <div className="tasks-page">
      <header className="tasks-head">
        {showSidebarButton ? (
          <button className="tasks-round" onClick={onToggleSidebar} title="Show sidebar">
            <PanelLeft />
          </button>
        ) : (
          <span className="tasks-round-spacer" />
        )}
        <h1>Boss profile</h1>
        <span className="tasks-round-spacer" />
      </header>

      <div className="tasks-scroll">
        <div className="tasks-column">
          <div className="boss-intro">
            What every employee knows about you. Tell any one of them something about yourself and it lands here, for all
            of them, from their next wake-up.
          </div>
          {error && <div className="tasks-error">{error}</div>}
          {lines === null && !error && <div className="tasks-note">loading…</div>}
          {lines?.length === 0 && <div className="tasks-note">Nothing yet.</div>}

          {lines && lines.length > 0 && (
            <div className="boss-list">
              {lines.map((line) =>
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
            </div>
          )}
        </div>
      </div>

      <AddLine onAdd={(text) => act(addBossLine(text))} />
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
          if (e.key === "Escape") onCancel()
        }}
      />
      <div className="boss-actions">
        <button className="boss-delete" onClick={onDelete} title="Delete this line">
          <Trash2 /> Delete
        </button>
        <span className="boss-spacer" />
        <button className="emp-pill" onClick={onCancel}>
          Cancel
        </button>
        <button className="emp-pill strong" disabled={!text.trim()} onClick={() => onSave(text.trim())}>
          Save
        </button>
      </div>
    </div>
  )
}

/** The composer at the foot, as on the Tasks page: a line, added on send. */
function AddLine({ onAdd }: { onAdd: (text: string) => Promise<boolean> }) {
  const [text, setText] = useState("")
  const [busy, setBusy] = useState(false)
  const ref = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.height = "auto"
    el.style.height = `${Math.min(el.scrollHeight, 5 * 26)}px`
  }, [text])

  const send = async () => {
    const value = text.trim()
    if (!value || busy) return
    setBusy(true)
    if (await onAdd(value)) setText("")
    setBusy(false)
  }

  return (
    <div className="tasks-composer">
      <div className="tasks-composer-box">
        <textarea
          ref={ref}
          rows={1}
          value={text}
          placeholder="Add a line for every employee"
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (isComposing(e)) return
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault()
              void send()
            }
          }}
        />
        <button className="tasks-composer-btn send" onClick={send} disabled={!text.trim() || busy} title="Add">
          {busy ? <Loader2 className="spin" /> : <ArrowUp />}
        </button>
      </div>
    </div>
  )
}

// "10-29", as the employees are told it.
function day(ms: number) {
  const d = new Date(ms)
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
}
