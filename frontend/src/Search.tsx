import { Search as SearchIcon } from "lucide-react"
import { useEffect, useMemo, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { searchSessions, type AgentInfo, type SearchHit } from "./api"
import { lastActive } from "./useLobby"

/**
 * ChatGPT's search: the sidebar's button opens it over everything. Empty, it
 * lists the latest chats; typed in, the sessions that have all the words, in
 * the server's order (`Loom.Agent.Search.ranked/2`): what the sidebar lists,
 * and behind "More" the rest — archived ones, employees', notices', tasks',
 * dreams'. On a phone the whole screen, on a desktop a panel.
 */
export function SearchSheet({
  sessions,
  onSelect,
  onClose,
}: {
  // Every session the page knows, archived and employees' included.
  sessions: AgentInfo[]
  onSelect: (id: string) => void
  onClose: () => void
}) {
  const [query, setQuery] = useState("")
  const [hits, setHits] = useState<SearchHit[] | null>(null)
  const [more, setMore] = useState(false)
  const input = useRef<HTMLInputElement>(null)
  const q = query.trim()

  useEffect(() => input.current?.focus(), [])

  // From the server, once typing pauses. The last answer stays until the
  // next one, so rows do not blink away on each key.
  useEffect(() => {
    setMore(false)
    if (!q) {
      setHits(null)
      return
    }
    const abort = new AbortController()
    const timer = setTimeout(() => searchSessions(q, abort.signal).then(setHits, () => {}), 200)
    return () => {
      clearTimeout(timer)
      abort.abort()
    }
  }, [q])

  const byId = useMemo(() => new Map(sessions.map((s) => [s.id, s])), [sessions])
  const words = useMemo(() => q.split(/\s+/).filter(Boolean), [q])

  const rows = useMemo(() => {
    if (!q) {
      const recents = sessions
        .filter((s) => s.kind == null && !s.archived_at)
        .sort((a, b) => lastActive(b) - lastActive(a))
        .slice(0, 30)
      return recents.map((session) => ({ session, snippet: null as string | null, tier: 1 as 1 | 2 }))
    }
    return (hits ?? []).flatMap((h) => {
      const session = byId.get(h.id)
      return session ? [{ session, snippet: h.snippet, tier: h.tier }] : []
    })
  }, [sessions, byId, q, hits])

  const listed = rows.filter((r) => r.tier === 1)
  const rest = rows.filter((r) => r.tier === 2)
  const shown = more ? rows : listed

  const pick = (id: string) => {
    onSelect(id)
    onClose()
  }

  return createPortal(
    <div className="search-sheet" onClick={onClose}>
      <div className="search-panel" onClick={(e) => e.stopPropagation()}>
        <div className="search-bar">
          <label className="search-field">
            <SearchIcon />
            <input
              ref={input}
              type="search"
              value={query}
              placeholder="Search chats"
              enterKeyHint="search"
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Escape") onClose()
                else if (e.key === "Enter" && shown[0]) pick(shown[0].session.id)
              }}
            />
          </label>
          <button className="search-cancel" onClick={onClose}>
            Cancel
          </button>
        </div>
        <div className="search-results">
          {!q && <div className="search-heading">Recents</div>}
          {shown.map(({ session, snippet, tier }, i) => (
            <div key={session.id} className="search-group">
              {tier === 2 && shown[i - 1]?.tier !== 2 && <div className="search-heading">More</div>}
              <button className="search-row" onClick={() => pick(session.id)}>
                <span className="search-title">
                  <span className="search-title-text">
                    <Marked text={session.title ?? session.id} words={words} />
                  </span>
                  {tag(session) && <span className="search-tag">{tag(session)}</span>}
                </span>
                {snippet && (
                  <span className="search-snippet">
                    <Marked text={snippet} words={words} />
                  </span>
                )}
              </button>
            </div>
          ))}
          {q && hits !== null && listed.length === 0 && (
            <div className="search-empty">
              {rest.length ? `Nothing in your chats mentions “${q}”.` : `No chats mention “${q}”.`}
            </div>
          )}
          {!more && rest.length > 0 && (
            <button className="search-more" onClick={() => setMore(true)}>
              More <span className="search-more-count">{rest.length}</span>
            </button>
          )}
        </div>
      </div>
    </div>,
    document.body,
  )
}

/** What a row that is not one of the user's own open chats is, in gray. */
function tag(s: AgentInfo): string | null {
  switch (s.kind) {
    case "employee_chat":
    case "employee_setup":
    case "employee_work":
      return "Employee"
    case "notice":
      return "Notice"
    case "dream":
      return "Dream"
    case "task":
      return "Task"
  }
  return s.archived_at ? "Archived" : null
}

/** The text with each place it has one of the words in bold. */
function Marked({ text, words }: { text: string; words: string[] }) {
  if (!words.length) return <>{text}</>
  const alt = words.map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")
  const parts = text.split(new RegExp(`(${alt})`, "gi"))
  return <>{parts.map((part, i) => (i % 2 ? <b key={i}>{part}</b> : part))}</>
}
