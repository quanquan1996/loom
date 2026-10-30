import { Bell, Check, CheckCircle2, History, MessageSquare, Moon, X } from "lucide-react"
import { useState } from "react"
import { createPortal } from "react-dom"
import { answerNotice, type Notice } from "./api"
import "./Notices.css"

/**
 * The bell (`Loom.Notices`): what the agents working for the user want them
 * to see, most urgent first. One list; a card is who, one line, and its
 * priority. Approving takes a tap here; anything else is answered where it
 * came from, which tapping the card opens.
 *
 * The bands, by priority: 0–2 urgent (notified at once), 3–5 important (one
 * notification at 20:00), 6–10 the rest.
 */

export const urgent = (n: Notice) => n.status === "open" && n.priority <= 2
export const important = (n: Notice) => n.status === "open" && n.priority >= 3 && n.priority <= 5

const BANDS: { label: string; tone: string; has: (n: Notice) => boolean }[] = [
  { label: "Urgent", tone: "urgent", has: (n) => n.priority <= 2 },
  { label: "Important", tone: "important", has: (n) => n.priority >= 3 && n.priority <= 5 },
  { label: "Other", tone: "other", has: (n) => n.priority >= 6 },
]

/** Most urgent first, then newest. */
export const openNotices = (notices: Notice[]) =>
  notices.filter((n) => n.status === "open").sort((a, b) => a.priority - b.priority || b.created_at - a.created_at)

/** The sidebar's bell: a count of the urgent ones, else a dot for important. */
export function BellButton({ notices, onClick }: { notices: Notice[]; onClick: () => void }) {
  const count = notices.filter(urgent).length
  const dot = count === 0 && notices.some(important)
  return (
    <button className="icon-btn bell-btn" onClick={onClick} title="Notifications">
      <Bell />
      {count > 0 && <span className="bell-count">{count > 9 ? "9+" : count}</span>}
      {dot && <span className="bell-dot" />}
    </button>
  )
}

export function NoticesSheet({
  notices,
  onOpen,
  onAnswered,
  onClose,
}: {
  notices: Notice[]
  onOpen: (n: Notice) => void
  onAnswered: (n: Notice) => void
  onClose: () => void
}) {
  const [history, setHistory] = useState(false)
  const open = openNotices(notices)
  const settled = notices.filter((n) => n.status !== "open").sort((a, b) => (b.done_at ?? 0) - (a.done_at ?? 0))

  return createPortal(
    <div className="search-sheet" onClick={onClose}>
      <div className="search-panel bell-panel" onClick={(e) => e.stopPropagation()}>
        <div className="bell-head">
          <span className="bell-title">{history ? "History" : "Notifications"}</span>
          <button
            className={"icon-btn" + (history ? " on" : "")}
            onClick={() => setHistory((h) => !h)}
            title={history ? "Back to the open ones" : "History"}
          >
            <History />
          </button>
          <button className="icon-btn" onClick={onClose} title="Close">
            <X />
          </button>
        </div>
        <div className="search-results bell-list">
          {history ? (
            settled.length ? (
              settled.map((n) => <Card key={n.id} n={n} onOpen={onOpen} onAnswered={onAnswered} />)
            ) : (
              <div className="search-empty">Nothing yet.</div>
            )
          ) : open.length ? (
            BANDS.map((band) => {
              const inBand = open.filter(band.has)
              return (
                inBand.length > 0 && (
                  <section key={band.label}>
                    <div className={"bell-band " + band.tone}>{band.label}</div>
                    {inBand.map((n) => (
                      <Card key={n.id} n={n} onOpen={onOpen} onAnswered={onAnswered} />
                    ))}
                  </section>
                )
              )
            })
          ) : (
            <div className="bell-empty">
              <CheckCircle2 />
              <span>All caught up</span>
            </div>
          )}
        </div>
      </div>
    </div>,
    document.body,
  )
}

function Card({ n, onOpen, onAnswered }: { n: Notice; onOpen: (n: Notice) => void; onAnswered: (n: Notice) => void }) {
  const [busy, setBusy] = useState(false)
  const tone = n.priority <= 2 ? "urgent" : n.priority <= 5 ? "important" : "other"
  const answer = async (approve: boolean) => {
    setBusy(true)
    try {
      onAnswered(await answerNotice(n.id, approve))
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      className={"bell-card " + tone + (n.status === "open" ? "" : " settled")}
      role="button"
      onClick={() => n.session && onOpen(n)}
    >
      <div className="bell-card-head">
        <SourceMark n={n} />
        <span className="bell-source">{n.source.name}</span>
        <span className="bell-age">· {when(n.updated_at)}</span>
        <span className={"bell-p " + tone}>P{n.priority}</span>
      </div>
      <div className="bell-summary">{n.summary}</div>
      {n.note && <div className="bell-note">{n.note}</div>}
      {n.status === "open" && n.needs === "approve" && (
        <div className="bell-acts" onClick={(e) => e.stopPropagation()}>
          <button className="bell-btn pri" disabled={busy} onClick={() => answer(true)}>
            <Check /> Approve
          </button>
          <button className="bell-btn" disabled={busy} onClick={() => answer(false)}>
            Reject
          </button>
        </div>
      )}
    </div>
  )
}

function SourceMark({ n }: { n: Notice }) {
  if (n.source.kind === "dream") return <Moon className="bell-mark" />
  if (n.source.kind === "employee") return <span className="emp-avatar sm">{[...n.source.name.trim()][0] ?? "?"}</span>
  return <MessageSquare className="bell-mark" />
}

/**
 * Over the composer, while going through the bell: back to it, or on to the
 * next one, without the list in between.
 */
export function NextBar({ left, onNext, onClose }: { left: number; onNext: () => void; onClose: () => void }) {
  return (
    <div className="bell-next">
      <Bell className="bell-mark" />
      <span className="bell-next-text">{left} more in the bell</span>
      <button className="bell-btn pri" onClick={onNext}>
        Next
      </button>
      <button className="icon-btn" onClick={onClose} title="Done going through">
        <X />
      </button>
    </div>
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
