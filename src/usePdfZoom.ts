import { useEffect, useRef, type RefObject } from "react";

export type ZoomPoint = { x: number; y: number };
type PinchEvent = Event & {
  scale?: number;
  clientX?: number;
  clientY?: number;
};
type ZoomCallbacks = {
  begin: (point: ZoomPoint) => number;
  update: (scale: number) => void;
  end: (scale: number) => void;
};

// Input only: live preview and the single persisted commit belong to the viewer.
export function usePdfZoom(
  body: RefObject<HTMLDivElement | null>,
  documentID: string,
  enabled: boolean,
  callbacks: ZoomCallbacks,
) {
  const latest = useRef(callbacks);
  latest.current = callbacks;
  useEffect(() => {
    const element = body.current;
    if (!element || !enabled) return;
    let active: "pinch" | "wheel" | null = null;
    let startScale = 1,
      scale = 1,
      frame = 0;
    let timer: ReturnType<typeof setTimeout> | undefined;
    function point(event: PinchEvent): ZoomPoint {
      const rect = element!.getBoundingClientRect();
      return {
        x:
          event.clientX !== undefined &&
          event.clientX >= rect.left &&
          event.clientX <= rect.right
            ? event.clientX - rect.left
            : rect.width / 2,
        y:
          event.clientY !== undefined &&
          event.clientY >= rect.top &&
          event.clientY <= rect.bottom
            ? event.clientY - rect.top
            : rect.height / 2,
      };
    }
    function begin(event: PinchEvent, kind: "pinch" | "wheel") {
      active = kind;
      startScale = scale = latest.current.begin(point(event));
    }
    function preview() {
      frame = 0;
      latest.current.update(scale);
    }
    function update(value: number) {
      if (!Number.isFinite(value) || value <= 0) return;
      scale = Math.min(4, Math.max(0.25, value));
      if (!frame) frame = requestAnimationFrame(preview);
    }
    function finish() {
      if (!active) return;
      clearTimeout(timer);
      cancelAnimationFrame(frame);
      frame = 0;
      active = null;
      latest.current.end(scale);
    }
    function start(event: PinchEvent) {
      event.preventDefault();
      // WebKit's scale is relative to the beginning of this gesture.
      if (active) finish();
      begin(event, "pinch");
    }
    function change(event: PinchEvent) {
      if (active !== "pinch") return;
      event.preventDefault();
      if (event.scale !== undefined) update(startScale * event.scale);
    }
    function end(event: PinchEvent) {
      change(event);
      finish();
    }
    function wheel(event: WheelEvent) {
      if (!event.ctrlKey && !event.metaKey) {
        if (active === "wheel") finish();
        return;
      }
      event.preventDefault();
      if (active === "pinch" || !event.deltaY) return;
      if (!active) begin(event, "wheel");
      const units =
        event.deltaMode === 1
          ? 16
          : event.deltaMode === 2
            ? element!.clientHeight
            : 1;
      const delta = Math.max(-100, Math.min(100, event.deltaY * units));
      update(scale * Math.exp(-delta * 0.005));
      clearTimeout(timer);
      timer = setTimeout(finish, 160);
    }
    element.addEventListener("gesturestart", start, { passive: false });
    element.addEventListener("gesturechange", change, { passive: false });
    element.addEventListener("gestureend", end, { passive: false });
    element.addEventListener("wheel", wheel, { passive: false });
    window.addEventListener("blur", finish);
    return () => {
      cancelAnimationFrame(frame);
      clearTimeout(timer);
      element.removeEventListener("gesturestart", start);
      element.removeEventListener("gesturechange", change);
      element.removeEventListener("gestureend", end);
      element.removeEventListener("wheel", wheel);
      window.removeEventListener("blur", finish);
    };
  }, [body, documentID, enabled]);
}
