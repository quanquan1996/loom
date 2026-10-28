import type { CSSProperties } from "react"

/**
 * A slider in Loom's hand: a hairline track filled up to a white thumb, as
 * iOS draws one. With `ticks`, each stop is a dot on the track — for a few
 * named stops rather than a range. The look is in Chat.css (`.slider`).
 */
export function Slider({
  min,
  max,
  step,
  value,
  onChange,
  label,
  valueText,
  ticks = false,
}: {
  min: number
  max: number
  step: number
  value: number
  onChange: (value: number) => void
  label: string
  valueText?: string
  ticks?: boolean
}) {
  const fill = max > min ? (value - min) / (max - min) : 0
  const stops = ticks ? Math.round((max - min) / step) + 1 : 0
  return (
    <div className="slider" style={{ "--fill": fill } as CSSProperties}>
      {ticks && (
        <div className="slider-ticks" aria-hidden>
          {Array.from({ length: stops }, (_, i) => (
            <span key={i} className={min + i * step <= value ? "on" : ""} />
          ))}
        </div>
      )}
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        aria-label={label}
        aria-valuetext={valueText}
        onChange={(e) => onChange(Number(e.target.value))}
      />
    </div>
  )
}
