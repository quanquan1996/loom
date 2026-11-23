// The parts of noVNC's RFB that `Browser.tsx` uses; the package ships no types.
declare module "@novnc/novnc" {
  export type CursorImage = { rgbaPixels: Uint8Array; w: number; h: number; hotx: number; hoty: number }
  export default class RFB extends EventTarget {
    static cursors: { none: CursorImage; dot: CursorImage }
    showDotCursor: boolean
    constructor(target: HTMLElement, url: string, options?: { wsProtocols?: string[] })
    scaleViewport: boolean
    clipViewport: boolean
    dragViewport: boolean
    background: string
    sendKey(keysym: number, code: string | null, down?: boolean): void
    sendCredentials(creds: { username?: string; password?: string; target?: string }): void
    disconnect(): void
  }
}
