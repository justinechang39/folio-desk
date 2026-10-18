import { useEffect, useRef, type RefObject } from "react";

// macOS WebKit reports pinch gestures separately from wheel events. Its scale
// is cumulative from gesturestart, not a multiplier for each gesturechange.
type PinchEvent = Event & { scale?: number };
export function usePdfZoom(
  body: RefObject<HTMLDivElement | null>,
  documentID: string | undefined,
  enabled: boolean,
  scale: number,
  onZoom: (zoom: number) => void,
  onFocus: () => void,
) {
  const callbacks = useRef({ onZoom, onFocus });
  callbacks.current = { onZoom, onFocus };
  const liveScale = useRef(scale);
  useEffect(() => {
    liveScale.current = scale;
  }, [scale]);
  useEffect(() => {
    const element = body.current;
    if (!element || !enabled) return;
    let startScale: number | null = null;
    let pending: number | null = null;
    let frame = 0;
    function flush() {
      cancelAnimationFrame(frame);
      frame = 0;
      if (pending === null) return;
      const zoom = pending;
      pending = null;
      callbacks.current.onZoom(zoom);
    }
    function zoomTo(value: number) {
      if (!Number.isFinite(value) || value <= 0) return;
      liveScale.current = Math.min(4, Math.max(0.25, value));
      pending = liveScale.current;
      if (!frame) frame = requestAnimationFrame(flush);
    }
    function start(event: Event) {
      event.preventDefault();
      startScale = liveScale.current;
      callbacks.current.onFocus();
    }
    function change(event: PinchEvent) {
      if (startScale === null) return;
      event.preventDefault();
      if (event.scale !== undefined) zoomTo(startScale * event.scale);
    }
    function end(event: PinchEvent) {
      change(event);
      startScale = null;
      flush();
    }
    function blur() {
      startScale = null;
      flush();
    }
    function wheel(event: WheelEvent) {
      if (!event.ctrlKey && !event.metaKey) return;
      event.preventDefault();
      // Avoid applying both event families for the same pinch.
      if (startScale !== null || !event.deltaY) return;
      const units =
        event.deltaMode === 1
          ? 16
          : event.deltaMode === 2
            ? element!.clientHeight
            : 1;
      const delta = Math.max(-100, Math.min(100, event.deltaY * units));
      callbacks.current.onFocus();
      zoomTo(liveScale.current * Math.exp(-delta * 0.005));
    }
    element.addEventListener("gesturestart", start, { passive: false });
    element.addEventListener("gesturechange", change, { passive: false });
    element.addEventListener("gestureend", end, { passive: false });
    element.addEventListener("wheel", wheel, { passive: false });
    window.addEventListener("blur", blur);
    return () => {
      cancelAnimationFrame(frame);
      element.removeEventListener("gesturestart", start);
      element.removeEventListener("gesturechange", change);
      element.removeEventListener("gestureend", end);
      element.removeEventListener("wheel", wheel);
      window.removeEventListener("blur", blur);
    };
  }, [body, documentID, enabled]);
}
