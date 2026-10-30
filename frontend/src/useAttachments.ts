import { useCallback, useEffect, useRef, useState } from "react"
import { isThumbnail } from "./api"
import { shrinkImage } from "./shrink"

/**
 * A file picked for the next message, held on this device. Nothing travels
 * until send: then the message's files go up together, in one request the
 * server stores all-or-nothing, and the message follows only once they are
 * there. So a message goes with every file it was sent with, or is marked as
 * not got through with all of them — never half. See `useAgent`'s `send`.
 */
export type LocalFile = {
  name: string
  size: number
  type: string
  // An image shown from the local copy, in the tray and in the bubble.
  preview: string | null
  // The bytes, scaled down if an image (shrink.ts). Memory only: a message
  // kept across a reload has lost them, and says so.
  blob?: Blob
}

/** One row in the composer's attachment tray. */
export type Attachment = LocalFile & {
  key: string
  // Still being scaled down; it can't be sent yet.
  preparing: boolean
}

export type Attachments = {
  items: Attachment[]
  /** What a submit carries: every file in the tray, ready. */
  ready: LocalFile[]
  preparing: boolean
  add: (files: File[]) => void
  remove: (key: string) => void
  clear: () => void
}

export function useAttachments(sessionId: string | null): Attachments {
  const [items, setItems] = useState<Attachment[]>([])
  const nextKey = useRef(0)

  // Switching session must not carry one conversation's attachments into
  // another.
  useEffect(() => setItems([]), [sessionId])

  const patch = useCallback((key: string, change: Partial<Attachment>) => {
    setItems((prev) =>
      prev.map((item) => (item.key === key ? { ...item, ...change } : item)),
    )
  }, [])

  const add = useCallback(
    (files: File[]) => {
      if (!sessionId || files.length === 0) return

      const rows: Attachment[] = files.map((file) => ({
        key: `a${nextKey.current++}`,
        name: file.name,
        size: file.size,
        type: file.type,
        // Never revoked: the sent bubble shows it too, until the server's copy
        // is seeded with it.
        preview: isThumbnail(file.type) ? URL.createObjectURL(file) : null,
        preparing: true,
      }))
      setItems((prev) => [...prev, ...rows])

      // Scaled down now, on the device, so send has nothing left to do but
      // upload. An image only; see shrink.ts.
      files.forEach((file, i) => {
        void shrinkImage(file).then((small) =>
          patch(rows[i].key, { name: small.name, size: small.size, blob: small, preparing: false }),
        )
      })
    },
    [sessionId, patch],
  )

  const remove = useCallback((key: string) => {
    setItems((prev) => prev.filter((item) => item.key !== key))
  }, [])

  const clear = useCallback(() => setItems([]), [])

  return {
    items,
    ready: items.map(({ name, size, type, preview, blob }) => ({ name, size, type, preview, blob })),
    preparing: items.some((item) => item.preparing),
    add,
    remove,
    clear,
  }
}

/**
 * Drag-and-drop onto a whole region.
 *
 * `dragEnter`/`dragLeave` fire for every child element the pointer crosses, so
 * the depth counter is what keeps the highlight from flickering off as the file
 * moves over a message bubble.
 */
export function useFileDrop(onFiles: (files: File[]) => void) {
  const [dragging, setDragging] = useState(false)
  const depth = useRef(0)

  const handlers = {
    onDragEnter: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      depth.current += 1
      setDragging(true)
    },
    onDragOver: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      // Without preventDefault the browser refuses the drop and opens the file
      // in a new tab instead.
      e.preventDefault()
      e.dataTransfer.dropEffect = "copy"
    },
    onDragLeave: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      depth.current = Math.max(0, depth.current - 1)
      if (depth.current === 0) setDragging(false)
    },
    onDrop: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      depth.current = 0
      setDragging(false)
      onFiles(Array.from(e.dataTransfer.files))
    },
  }

  return { dragging, handlers }
}

// Dragged text and dragged links also raise these events; only a file drag is
// ours to take.
function hasFiles(e: React.DragEvent): boolean {
  return Array.from(e.dataTransfer.types).includes("Files")
}
