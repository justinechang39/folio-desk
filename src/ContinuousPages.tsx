import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type RefObject,
} from "react";
import {
  TextLayer,
  type PDFDocumentProxy,
  type PDFPageProxy,
} from "pdfjs-dist/legacy/build/pdf.mjs";
import { LoaderCircle } from "lucide-react";
import type { Doc } from "./model";

type Metric = { width: number; height: number; rotation: number };
type PageBox = Metric & { top: number; scale: number; number: number };
const GAP = 20,
  PADDING = 24;
export function arrangePages(
  metrics: Metric[],
  doc: Pick<Doc, "fit" | "zoom" | "rotation">,
  size: { width: number; height: number },
): PageBox[] {
  let top = PADDING;
  return metrics.map((metric, index) => {
    const rotated = doc.rotation % 180 !== 0;
    const width = rotated ? metric.height : metric.width,
      height = rotated ? metric.width : metric.height;
    const availableWidth = Math.max(100, size.width - PADDING * 2),
      availableHeight = Math.max(100, size.height - PADDING * 2);
    const scale =
      doc.fit === "width"
        ? availableWidth / width
        : doc.fit === "page"
          ? Math.min(availableWidth / width, availableHeight / height)
          : doc.zoom;
    const box = {
      width: width * scale,
      height: height * scale,
      rotation: (metric.rotation + doc.rotation) % 360,
      scale,
      top,
      number: index + 1,
    };
    top += box.height + GAP;
    return box;
  });
}
export function pageAt(boxes: PageBox[], position: number): number {
  let lo = 0,
    hi = boxes.length - 1;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (boxes[mid].top + boxes[mid].height + GAP <= position) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}
function PageCanvas({
  pdf,
  box,
  pixelBudget,
}: {
  pdf: PDFDocumentProxy;
  box: PageBox;
  pixelBudget: number;
}) {
  const sheet = useRef<HTMLDivElement>(null);
  const [busy, setBusy] = useState(true),
    [error, setError] = useState("");
  useEffect(() => {
    const target = sheet.current!;
    target.replaceChildren();
    setBusy(true);
    setError("");
    let cancelled = false,
      render: ReturnType<PDFPageProxy["render"]> | undefined,
      text: TextLayer | undefined,
      page: PDFPageProxy | undefined;
    pdf
      .getPage(box.number)
      .then(async (result) => {
        page = result;
        if (cancelled) return;
        const viewport = page.getViewport({
          scale: box.scale,
          rotation: box.rotation,
        });
        const ratio = Math.min(
          window.devicePixelRatio || 1,
          Math.sqrt(pixelBudget / (viewport.width * viewport.height)),
        );
        const canvas = document.createElement("canvas");
        canvas.width = Math.max(1, Math.floor(viewport.width * ratio));
        canvas.height = Math.max(1, Math.floor(viewport.height * ratio));
        canvas.style.width = "100%";
        canvas.style.height = "100%";
        target.append(canvas);
        render = page.render({
          canvas,
          viewport,
          transform: [ratio, 0, 0, ratio, 0, 0],
        });
        await render.promise;
        if (cancelled) return;
        const layer = document.createElement("div");
        layer.className = "textLayer";
        target.append(layer);
        text = new TextLayer({
          textContentSource: page.streamTextContent(),
          container: layer,
          viewport,
        });
        await text.render();
        if (!cancelled) setBusy(false);
      })
      .catch((e) => {
        if (!cancelled && e?.name !== "RenderingCancelledException") {
          setError(String(e.message ?? e));
          setBusy(false);
        }
      });
    return () => {
      cancelled = true;
      render?.cancel();
      text?.cancel();
      // Release page operator lists after the active render has stopped.
      if (render)
        void render.promise.catch(() => {}).then(() => page?.cleanup());
      else page?.cleanup();
    };
  }, [pdf, box.number, box.scale, box.rotation, pixelBudget]);
  return (
    <div
      className="page-frame"
      data-page={box.number}
      style={{ top: box.top, width: box.width, height: box.height }}
      aria-label={`Page ${box.number}`}
    >
      <div
        className="pdf-sheet"
        ref={sheet}
        style={
          {
            width: "100%",
            height: "100%",
            "--total-scale-factor": box.scale,
          } as React.CSSProperties
        }
      />
      {busy && (
        <span className="page-loading">
          <LoaderCircle size={14} className="spin" />
          Page {box.number}
        </span>
      )}
      {error && (
        <div className="page-render-error" role="alert">
          Page {box.number}: {error}
        </div>
      )}
    </div>
  );
}
export default function ContinuousPages({
  pdf,
  doc,
  size,
  scrollRef,
  onScrollPosition,
  onScale,
}: {
  pdf: PDFDocumentProxy;
  doc: Doc;
  size: { width: number; height: number };
  scrollRef: RefObject<HTMLDivElement | null>;
  onScrollPosition: (page: number, offset: number) => void;
  onScale: (scale: number) => void;
}) {
  const [metrics, setMetrics] = useState<Metric[]>([]),
    [error, setError] = useState(""),
    [scrollTop, setScrollTop] = useState(0);
  const scaleCallback = useRef(onScale);
  scaleCallback.current = onScale;
  const callback = useRef(onScrollPosition);
  callback.current = onScrollPosition;
  const lastReported = useRef<{ page: number; offset: number } | null>(null),
    programmatic = useRef<number | null>(null),
    previousBoxes = useRef<PageBox[] | null>(null);
  useEffect(() => {
    let cancelled = false;
    setMetrics([]);
    setError("");
    async function measure() {
      const dimensions: Metric[] = [];
      // Only parse page geometry here. Rasterize a small visible window below.
      for (let start = 1; start <= pdf.numPages; start += 16) {
        if (cancelled) return;
        const batch = await Promise.all(
          Array.from(
            { length: Math.min(16, pdf.numPages - start + 1) },
            async (_, i) => {
              const page = await pdf.getPage(start + i),
                v = page.getViewport({ scale: 1 });
              return {
                width: v.width,
                height: v.height,
                rotation: page.rotate,
              };
            },
          ),
        );
        dimensions.push(...batch);
      }
      if (!cancelled) setMetrics(dimensions);
    }
    void measure().catch((e) => {
      if (!cancelled)
        setError(`Couldn’t prepare pages: ${String(e.message ?? e)}`);
    });
    return () => {
      cancelled = true;
    };
  }, [pdf]);
  const boxes = useMemo(
    () => arrangePages(metrics, doc, size),
    [metrics, doc.fit, doc.zoom, doc.rotation, size.width, size.height],
  );
  const currentBox = boxes[Math.min(doc.page, boxes.length) - 1];
  useEffect(() => {
    if (currentBox) scaleCallback.current(currentBox.scale);
  }, [currentBox?.scale]);
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el || !boxes.length) return;
    const own = lastReported.current;
    const geometryChanged = previousBoxes.current !== boxes;
    previousBoxes.current = boxes;
    if (
      !geometryChanged &&
      own?.page === doc.page &&
      Math.abs(own.offset - (doc.offset ?? 0)) < 0.002
    )
      return;
    const box = boxes[Math.min(doc.page, boxes.length) - 1];
    const target = Math.min(
      Math.max(0, box.top - PADDING + (doc.offset ?? 0) * box.height),
      Math.max(0, el.scrollHeight - el.clientHeight),
    );
    programmatic.current = target;
    el.scrollTop = target;
    setScrollTop(target);
  }, [boxes, doc.page, doc.offset, scrollRef]);
  useEffect(() => {
    const el = scrollRef.current;
    if (!el || !boxes.length) return;
    let raf = 0,
      timer: ReturnType<typeof setTimeout> | undefined;
    function report() {
      const top = el!.scrollTop,
        box =
          boxes[
            top > 0 && top >= el!.scrollHeight - el!.clientHeight - 2
              ? boxes.length - 1
              : pageAt(boxes, top + PADDING)
          ];
      const offset = Math.max(
        0,
        Math.min(0.999, (top + PADDING - box.top) / box.height),
      );
      lastReported.current = { page: box.number, offset };
      callback.current(box.number, offset);
    }
    function scroll() {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        const top = el!.scrollTop;
        setScrollTop(top);
        if (
          programmatic.current !== null &&
          Math.abs(top - programmatic.current) < 2
        ) {
          programmatic.current = null;
          return;
        }
        programmatic.current = null;
        // Page changes are immediate; fractional position is saved when scrolling settles.
        const box =
          boxes[
            top > 0 && top >= el!.scrollHeight - el!.clientHeight - 2
              ? boxes.length - 1
              : pageAt(boxes, top + PADDING)
          ];
        if (box.number !== lastReported.current?.page) report();
        clearTimeout(timer);
        timer = setTimeout(report, 120);
      });
    }
    el.addEventListener("scroll", scroll, { passive: true });
    return () => {
      el.removeEventListener("scroll", scroll);
      cancelAnimationFrame(raf);
      clearTimeout(timer);
    };
  }, [boxes, scrollRef]);
  if (error)
    return (
      <div className="pane-message error-state" role="alert">
        {error}
      </div>
    );
  if (!boxes.length)
    return (
      <div className="pane-message">
        <LoaderCircle className="spin" size={24} />
        <span>Preparing pages…</span>
      </div>
    );
  const first = Math.max(0, pageAt(boxes, Math.max(0, scrollTop)) - 1),
    last = Math.min(
      boxes.length - 1,
      pageAt(boxes, scrollTop + size.height) + 1,
    );
  const visible = boxes.slice(first, last + 1),
    width = Math.max(size.width, ...boxes.map((b) => b.width + PADDING * 2)),
    tail = boxes[boxes.length - 1];
  return (
    <div
      className="continuous-pages"
      style={{ height: tail.top + tail.height + PADDING, width }}
    >
      {visible.map((box) => (
        <PageCanvas
          key={box.number}
          pdf={pdf}
          box={box}
          pixelBudget={Math.floor(16_000_000 / visible.length)}
        />
      ))}
    </div>
  );
}
