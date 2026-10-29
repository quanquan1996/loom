// Which engine runs a session, as a line drawing of its maker's mark: Claude's
// spark, OpenAI's knot (Tabler's brand-openai, MIT) and Kiro's ghost (traced
// from its logo). Stroked in currentColor like the lucide icons around it.

const CLAUDE =
  "M12.25 10.22L13.32 2.59M13.25 10.71L17.56 6.25M13.77 11.69L21.36 10.35M13.62 12.79L18.74 15.29M12.85 13.59L16.23 19.95M11.75 13.78L10.82 20.42M10.75 13.29L5.4 18.83M10.23 12.31L4.61 13.3M10.38 11.21L3.91 8.05M11.15 10.41L8.24 4.94"

const OPENAI = [
  "M11.217 19.384a3.501 3.501 0 0 0 6.783 -1.217v-5.167l-6 -3.35",
  "M5.214 15.014a3.501 3.501 0 0 0 4.446 5.266l4.34 -2.534v-6.946",
  "M6 7.63c-1.391 -.236 -2.787 .395 -3.534 1.689a3.474 3.474 0 0 0 1.271 4.745l4.263 2.514l6 -3.348",
  "M12.783 4.616a3.501 3.501 0 0 0 -6.783 1.217v5.067l6 3.45",
  "M18.786 8.986a3.501 3.501 0 0 0 -4.446 -5.266l-4.34 2.534v6.946",
  "M18 16.302c1.391 .236 2.787 -.395 3.534 -1.689a3.474 3.474 0 0 0 -1.271 -4.745l-4.308 -2.514l-5.955 3.42",
]

const KIRO =
  "M4.594 6.677C6.67-2.226 18.746-2.211 21.16 6.632c.353 1.297 1.725 7.582-1.673 13.747-1.545 2.797-5.841 5.49-6.99 1.883C8.6 25.477 3.315 24.1 5.789 18.609l-.318.143c-3.57 1.305-3.863-1.208-3.173-2.513.45-.84.727-1.335.937-1.897.353-.975.458-1.568.593-2.498.27-1.837.277-3.607.765-5.167z"

const NAMES: Record<string, string> = { claude_code: "Claude Code", codex: "Codex", kiro: "Kiro" }

export function BackendIcon({ backend, title }: { backend: string; title?: string }) {
  const label = title ?? NAMES[backend] ?? backend
  let body
  if (backend === "claude_code") body = <path d={CLAUDE} />
  else if (backend === "codex") body = OPENAI.map((d) => <path key={d} d={d} />)
  else if (backend === "kiro")
    body = (
      // The logo runs past its 24 box; shrink it to sit with the other two.
      <g transform="translate(12 12) scale(0.84) translate(-12 -11.6)">
        <path d={KIRO} />
        <ellipse cx="13" cy="8.6" rx="1" ry="1.45" fill="currentColor" stroke="none" />
        <ellipse cx="17" cy="8.6" rx="1" ry="1.45" fill="currentColor" stroke="none" />
      </g>
    )
  else return <span className={"session-backend " + backend}>{backend}</span>
  return (
    <span className={"session-backend " + backend} title={label} aria-label={label} role="img">
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.75"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        {body}
      </svg>
    </span>
  )
}
