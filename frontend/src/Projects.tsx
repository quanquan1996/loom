import { X } from "lucide-react"
import { useEffect, useState } from "react"
import { createPortal } from "react-dom"
import { createProject, deleteProject, updateProject, type Project } from "./api"
import { Confirm } from "./Confirm"

/**
 * Make a project, or edit one: its name and the instructions every session in
 * it is given. The directory is chosen once, when it is made — empty for a
 * workspace of Loom's own, or a path to bind an existing one (a checkout) —
 * because each session's working directory is fixed for its life.
 *
 * Deleting takes the project's sessions with it, and the workspace if Loom
 * made it; a bound directory is left as it is. So it asks first, and says
 * which.
 */
export function ProjectDialog({
  project,
  sessionCount,
  onSaved,
  onClose,
}: {
  // null to make a new one.
  project: Project | null
  sessionCount: number
  onSaved: (project: Project) => void
  onClose: () => void
}) {
  const [name, setName] = useState(project?.name ?? "")
  const [dir, setDir] = useState("")
  const [instructions, setInstructions] = useState(project?.instructions ?? "")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [asking, setAsking] = useState(false)

  useEffect(() => {
    if (asking) return
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose()
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose, asking])

  const save = async () => {
    if (name.trim() === "" || busy) return
    setBusy(true)
    try {
      const saved = project
        ? await updateProject(project.id, { name, instructions })
        : await createProject({ name, instructions, ...(dir.trim() && { dir: dir.trim() }) })
      onSaved(saved)
      onClose()
    } catch (e) {
      setError((e as Error).message)
      setBusy(false)
    }
  }

  const sessions = `${sessionCount} session${sessionCount === 1 ? "" : "s"}`

  return createPortal(
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal project-dialog" role="dialog" aria-label={project ? "Project" : "New project"}>
        <div className="modal-head">
          <span>{project ? "Project" : "New project"}</span>
          <button className="icon-btn" onClick={onClose} title="Close">
            <X />
          </button>
        </div>

        <form
          className="project-form"
          onSubmit={(e) => {
            e.preventDefault()
            void save()
          }}
        >
          <label>
            <span>Name</span>
            <input value={name} autoFocus onChange={(e) => setName(e.target.value)} placeholder="e.g. Blog" />
          </label>

          {project ? (
            <label>
              <span>Workspace{project.bound ? " (bound)" : ""}</span>
              <code className="project-path">{project.workspace}</code>
            </label>
          ) : (
            <label>
              <span>Directory</span>
              <input
                value={dir}
                onChange={(e) => setDir(e.target.value)}
                placeholder="empty for a new one, or e.g. ~/code/app"
                autoCapitalize="off"
                autoCorrect="off"
                spellCheck={false}
              />
              <small>Every session in the project starts here. This cannot be changed later.</small>
            </label>
          )}

          <label>
            <span>Instructions</span>
            <textarea
              value={instructions}
              rows={7}
              onChange={(e) => setInstructions(e.target.value)}
              placeholder="What every session in this project should know or do."
            />
            <small>Added to each session's system prompt. Claude Code sessions pick up a change on their next turn.</small>
          </label>

          {error && <div className="device-error">{error}</div>}

          <div className="confirm-actions">
            {project && (
              <button type="button" className="text-btn danger project-delete" onClick={() => setAsking(true)}>
                Delete
              </button>
            )}
            <button type="button" className="text-btn" onClick={onClose}>
              Cancel
            </button>
            <button type="submit" className="text-btn primary" disabled={name.trim() === "" || busy}>
              {project ? "Save" : "Create"}
            </button>
          </div>
        </form>
      </div>

      {asking && project && (
        <Confirm
          title={`Delete ${project.name}?`}
          detail={
            `Its ${sessions} and their history` +
            (project.bound
              ? `. ${project.workspace} is left as it is.`
              : `, and the workspace ${project.workspace} with everything in it.`) +
            " This cannot be undone."
          }
          onYes={async () => {
            await deleteProject(project.id)
            onClose()
          }}
          onClose={() => setAsking(false)}
        />
      )}
    </div>,
    document.body,
  )
}
