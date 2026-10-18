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
import { usePdfZoom, type ZoomPoint } from "./usePdfZoom";

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
type Anchor = { page: number; x: number; y: number; point: ZoomPoint };
type Interaction = { anchor: Anchor };
function contentWidth(boxes: PageBox[], width: number) {
  return boxes.reduce((w, box) => Math.max(w, box.width + PADDING * 2), width);
}
function anchoredScroll(
  boxes: PageBox[],
  anchor: Anchor,
  size: { width: number; height: number },
) {
  const box = boxes[anchor.page - 1],
    tail = boxes[boxes.length - 1];
  const width = contentWidth(boxes, size.width);
  return {
    top: Math.max(
      0,
      Math.min(
        tail.top + tail.height + PADDING - size.height,
        box.top + box.height * anchor.y - anchor.point.y,
      ),
    ),
    left: Math.max(
      0,
      Math.min(
        width - size.width,
        (width - box.width) / 2 + box.width * anchor.x - anchor.point.x,
      ),
    ),
  };
}
function positionAt(boxes: PageBox[], top: number) {
  const box = boxes[pageAt(boxes, top + PADDING)];
  return {
    page: box.number,
    offset: Math.max(
      0,
      Math.min(0.999, (top + PADDING - box.top) / box.height),
    ),
  };
}
function PageCanvas({
  pdf,
  box,
  pixelBudget,
  zooming,
}: {
  pdf: PDFDocumentProxy;
  box: PageBox;
  pixelBudget: number;
  zooming: boolean;
}) {
  // Existing pages keep their render recipe while pinching. Newly exposed
  // pages start at the live scale rather than allocating oversized bitmaps.
  const recipe = useRef({ box, pixelBudget });
  if (!zooming) recipe.current = { box, pixelBudget };
  const renderBox = recipe.current.box;
  const sheet = useRef<HTMLDivElement>(null);
  const loadedPage = useRef<PDFPageProxy | null>(null);
  const activeRender = useRef<ReturnType<PDFPageProxy["render"]> | null>(null);
  useEffect(
    () => () => {
      const page = loadedPage.current,
        render = activeRender.current;
      if (render)
        void render.promise.catch(() => {}).then(() => page?.cleanup());
      else page?.cleanup();
    },
    [pdf, box.number],
  );
  const [busy, setBusy] = useState(true),
    [error, setError] = useState("");
  const displayBox = useRef(box);
  displayBox.current = box;
  const rendered = useRef<{ width: number; layer: HTMLDivElement } | null>(
    null,
  );
  function alignText() {
    const current = rendered.current;
    if (current)
      current.layer.style.transform = `scale(${displayBox.current.width / current.width})`;
  }
  useLayoutEffect(alignText, [box.width]);
  const ratio = Math.min(
    window.devicePixelRatio || 1,
    Math.sqrt(
      recipe.current.pixelBudget / (renderBox.width * renderBox.height),
    ),
  );
  const rasterWidth = Math.max(1, Math.floor(renderBox.width * ratio));
  const rasterHeight = Math.max(1, Math.floor(renderBox.height * ratio));
  useEffect(() => {
    const target = sheet.current!;
    // Keep the last complete bitmap until its replacement is fully rendered.
    setBusy(!target.querySelector("canvas"));
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
        loadedPage.current = page;
        const viewport = page.getViewport({
          scale: renderBox.scale,
          rotation: renderBox.rotation,
        });
        const canvas = document.createElement("canvas");
        canvas.width = rasterWidth;
        canvas.height = rasterHeight;
        canvas.style.width = "100%";
        canvas.style.height = "100%";
        render = page.render({
          canvas,
          viewport,
          transform: [
            rasterWidth / viewport.width,
            0,
            0,
            rasterHeight / viewport.height,
            0,
            0,
          ],
        });
        activeRender.current = render;
        await render.promise;
        if (cancelled) return;
        const layer = document.createElement("div");
        layer.className = "textLayer";
        layer.style.width = `${viewport.width}px`;
        layer.style.height = `${viewport.height}px`;
        layer.style.setProperty(
          "--total-scale-factor",
          String(renderBox.scale),
        );
        text = new TextLayer({
          textContentSource: page.streamTextContent(),
          container: layer,
          viewport,
        });
        await text.render();
        if (!cancelled) {
          rendered.current = { width: viewport.width, layer };
          alignText();
          target.replaceChildren(canvas, layer);
          target.dataset.renderScale = String(renderBox.scale);
          setBusy(false);
        }
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
    };
  }, [
    pdf,
    box.number,
    renderBox.scale,
    renderBox.rotation,
    rasterWidth,
    rasterHeight,
  ]);
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
  onZoomCommit,
  onFocus,
}: {
  pdf: PDFDocumentProxy;
  doc: Doc;
  size: { width: number; height: number };
  scrollRef: RefObject<HTMLDivElement | null>;
  onScrollPosition: (page: number, offset: number) => void;
  onScale: (scale: number) => void;
  onZoomCommit: (patch: Partial<Doc>) => void;
  onFocus: () => void;
}) {
  const [metrics, setMetrics] = useState<Metric[]>([]),
    [error, setError] = useState(""),
    [scrollTop, setScrollTop] = useState(0);
  const [previewZoom, setPreviewZoom] = useState<number | null>(null);
  const interaction = useRef<Interaction | null>(null);
  const commitScroll = useRef<{ top: number; left: number } | null>(null);
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
    () =>
      size.width > 0 && size.height > 0
        ? arrangePages(
            metrics,
            previewZoom === null
              ? doc
              : { ...doc, fit: "manual", zoom: previewZoom },
            size,
          )
        : [],
    [
      metrics,
      doc.fit,
      doc.zoom,
      doc.rotation,
      size.width,
      size.height,
      previewZoom,
    ],
  );
  usePdfZoom(scrollRef, doc.id, boxes.length > 0, {
    begin(point) {
      const el = scrollRef.current!;
      const box = boxes[pageAt(boxes, el.scrollTop + point.y)];
      const width = contentWidth(boxes, size.width);
      interaction.current = {
        anchor: {
          page: box.number,
          point,
          x: (el.scrollLeft + point.x - (width - box.width) / 2) / box.width,
          y: (el.scrollTop + point.y - box.top) / box.height,
        },
      };
      onFocus();
      return box.scale;
    },
    update(zoom) {
      setPreviewZoom(zoom);
    },
    end(zoom) {
      const live = interaction.current;
      if (!live) return;
      const next = arrangePages(metrics, { ...doc, fit: "manual", zoom }, size);
      const scroll = anchoredScroll(next, live.anchor, size);
      const position = positionAt(next, scroll.top);
      commitScroll.current = scroll;
      lastReported.current = position;
      interaction.current = null;
      setPreviewZoom(null);
      // Persist once, with the anchored reading position in the same update.
      onZoomCommit({ fit: "manual", zoom, ...position });
    },
  });
  const currentBox = boxes[Math.min(doc.page, boxes.length) - 1];
  useEffect(() => {
    if (currentBox) scaleCallback.current(currentBox.scale);
  }, [currentBox?.scale]);
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el || !boxes.length) return;
    const live = interaction.current;
    const anchored = live
      ? anchoredScroll(boxes, live.anchor, size)
      : commitScroll.current;
    if (anchored) {
      commitScroll.current = null;
      previousBoxes.current = boxes;
      el.scrollLeft = anchored.left;
      el.scrollTop = anchored.top;
      programmatic.current = el.scrollTop;
      setScrollTop(el.scrollTop);
      return;
    }
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
  }, [boxes, doc.page, doc.offset, scrollRef, previewZoom]);
  useEffect(() => {
    const el = scrollRef.current;
    if (!el || !boxes.length) return;
    let raf = 0,
      timer: ReturnType<typeof setTimeout> | undefined;
    function report() {
      if (interaction.current || commitScroll.current) return;
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
        if (interaction.current || commitScroll.current) return;
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
  // Use the target position in this render, avoiding a frame of the old virtual window.
  const visibleTop = interaction.current
    ? anchoredScroll(boxes, interaction.current.anchor, size).top
    : (commitScroll.current?.top ?? scrollTop);
  const first = Math.max(0, pageAt(boxes, Math.max(0, visibleTop)) - 1),
    last = Math.min(
      boxes.length - 1,
      pageAt(boxes, visibleTop + size.height) + 1,
    );
  const visible = boxes.slice(first, last + 1),
    width = contentWidth(boxes, size.width),
    tail = boxes[boxes.length - 1];
  return (
    <div
      className="continuous-pages"
      data-zooming={previewZoom !== null ? "true" : undefined}
      style={{ height: tail.top + tail.height + PADDING, width }}
    >
      {visible.map((box) => (
        <PageCanvas
          key={box.number}
          pdf={pdf}
          box={box}
          zooming={previewZoom !== null}
          pixelBudget={Math.floor(16_000_000 / visible.length)}
        />
      ))}
    </div>
  );
}
