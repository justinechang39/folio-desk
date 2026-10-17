import { useEffect, useRef, useState } from "react";
import {
  getDocument,
  GlobalWorkerOptions,
  TextLayer,
  type PDFDocumentProxy,
} from "pdfjs-dist/legacy/build/pdf.mjs";
import workerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";
import {
  ChevronLeft,
  ChevronRight,
  Minus,
  Plus,
  RotateCw,
  Scan,
  MoveHorizontal,
  FilePlus2,
  LockKeyhole,
  LoaderCircle,
  X,
  GripVertical,
  Search,
  Maximize2,
  Minimize2,
} from "lucide-react";
import type { Doc } from "./model";
import { readPdf } from "./bridge";
GlobalWorkerOptions.workerSrc = workerUrl;
export function Tool({
  label,
  children,
  ...props
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { label: string }) {
  return (
    <button
      type="button"
      className="icon-button"
      title={label}
      aria-label={label}
      {...props}
    >
      {children}
    </button>
  );
}
type Props = {
  doc?: Doc;
  slot: number;
  focused: boolean;
  expanded: boolean;
  onFocus: () => void;
  onOpen: () => void;
  onPatch: (patch: Partial<Doc>) => void;
  onPage: (page: number) => void;
  onCount: (count: number) => void;
  onScale: (scale: number) => void;
  onHide: () => void;
  onExpand: () => void;
  onDrag: (event: React.DragEvent) => void;
  onDrop: (event: React.DragEvent) => void;
  onMove: () => void;
};
export default function PdfPane(p: Props) {
  const { doc } = p;
  const [pdf, setPdf] = useState<PDFDocumentProxy | null>(null),
    [error, setError] = useState(""),
    [rendering, setRendering] = useState(false);
  const [unlock, setUnlock] = useState<{
      submit: (password: string) => void;
      wrong: boolean;
    } | null>(null),
    [password, setPassword] = useState("");
  const [size, setSize] = useState({ width: 0, height: 0 }),
    [scale, setScale] = useState(1),
    [pageInput, setPageInput] = useState("1");
  const [searchOpen, setSearchOpen] = useState(false),
    [query, setQuery] = useState(""),
    [hits, setHits] = useState<number[]>([]),
    [searching, setSearching] = useState(false),
    [searched, setSearched] = useState(false);
  const searchGeneration = useRef(0),
    body = useRef<HTMLDivElement>(null),
    sheet = useRef<HTMLDivElement>(null);
  const countRef = useRef(p.onCount);
  countRef.current = p.onCount;
  useEffect(() => {
    setPdf(null);
    setError("");
    setUnlock(null);
    setPassword("");
    setHits([]);
    setSearched(false);
    setQuery("");
    searchGeneration.current++;
    if (!doc) return;
    let disposed = false;
    let task: ReturnType<typeof getDocument> | undefined;
    readPdf(doc.path)
      .then((bytes) => {
        if (disposed) return;
        task = getDocument({
          data: bytes,
          cMapUrl: "/pdfjs/cmaps/",
          cMapPacked: true,
          standardFontDataUrl: "/pdfjs/standard_fonts/",
          wasmUrl: "/pdfjs/wasm/",
          enableXfa: false,
        });
        task.onPassword = (
          submit: (password: string) => void,
          reason: number,
        ) => {
          if (!disposed) setUnlock({ submit, wrong: reason === 2 });
        };
        return task.promise;
      })
      .then((result) => {
        if (result && !disposed) {
          setUnlock(null);
          setPdf(result);
          countRef.current(result.numPages);
        }
      })
      .catch((e) => {
        if (!disposed) setError(e instanceof Error ? e.message : String(e));
      });
    return () => {
      disposed = true;
      searchGeneration.current++;
      void task?.destroy();
    };
  }, [doc?.path]);
  useEffect(() => {
    const el = body.current;
    if (!el) return;
    const observer = new ResizeObserver((entries) => {
      const r = entries[0].contentRect;
      setSize({ width: r.width, height: r.height });
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [!!doc]);
  useEffect(() => {
    setPageInput(String(doc?.page ?? 1));
  }, [doc?.page]);
  useEffect(() => {
    if (!pdf || !doc || !sheet.current || size.width === 0) return;
    let cancelled = false;
    let render:
      | ReturnType<Awaited<ReturnType<PDFDocumentProxy["getPage"]>>["render"]>
      | undefined;
    let text: TextLayer | undefined;
    const target = sheet.current;
    target.replaceChildren();
    setRendering(true);
    pdf
      .getPage(Math.min(doc.page, pdf.numPages))
      .then(async (page) => {
        if (cancelled) return;
        const rotation = (page.rotate + doc.rotation) % 360;
        const base = page.getViewport({ scale: 1, rotation });
        const width = Math.max(100, size.width - 48),
          height = Math.max(100, size.height - 48);
        const zoom =
          doc.fit === "page"
            ? Math.min(width / base.width, height / base.height)
            : doc.fit === "width"
              ? width / base.width
              : doc.zoom;
        setScale(zoom);
        p.onScale(zoom);
        const viewport = page.getViewport({ scale: zoom, rotation });
        const pixelRatio = Math.min(
          window.devicePixelRatio || 1,
          Math.sqrt(12_000_000 / (viewport.width * viewport.height)),
        );
        const canvas = document.createElement("canvas");
        canvas.width = Math.floor(viewport.width * pixelRatio);
        canvas.height = Math.floor(viewport.height * pixelRatio);
        canvas.style.width = `${viewport.width}px`;
        canvas.style.height = `${viewport.height}px`;
        target.style.width = `${viewport.width}px`;
        target.style.height = `${viewport.height}px`;
        target.style.setProperty("--total-scale-factor", String(zoom));
        target.append(canvas);
        render = page.render({
          canvas,
          viewport,
          transform: [pixelRatio, 0, 0, pixelRatio, 0, 0],
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
        if (!cancelled) setRendering(false);
      })
      .catch((e) => {
        if (!cancelled && e?.name !== "RenderingCancelledException") {
          setError(`Could not render this page: ${e.message}`);
          setRendering(false);
        }
      });
    body.current?.scrollTo(0, 0);
    return () => {
      cancelled = true;
      render?.cancel();
      text?.cancel();
    };
  }, [pdf, doc?.page, doc?.zoom, doc?.fit, doc?.rotation, size]);
  useEffect(() => {
    const element = body.current;
    if (!element) return;
    function wheel(e: WheelEvent) {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        p.onPatch({
          fit: "manual",
          zoom: Math.min(
            4,
            Math.max(0.25, scale * (e.deltaY > 0 ? 0.95 : 1.05)),
          ),
        });
      }
    }
    element.addEventListener("wheel", wheel, { passive: false });
    return () => element.removeEventListener("wheel", wheel);
  }, [scale, p.onPatch]);
  async function find() {
    if (!pdf || !query.trim()) return;
    const generation = ++searchGeneration.current;
    setSearching(true);
    setSearched(false);
    setHits([]);
    const results: number[] = [];
    try {
      for (let page = 1; page <= pdf.numPages; page++) {
        if (generation !== searchGeneration.current) return;
        const text = await (await pdf.getPage(page)).getTextContent();
        if (
          text.items
            .map((i) => ("str" in i ? i.str : ""))
            .join(" ")
            .toLocaleLowerCase()
            .includes(query.trim().toLocaleLowerCase())
        )
          results.push(page);
      }
      if (generation === searchGeneration.current) {
        setHits(results);
        setSearched(true);
        if (results[0]) p.onPage(results[0]);
      }
    } catch {
      if (generation === searchGeneration.current)
        setError("Could not search this document.");
    } finally {
      if (generation === searchGeneration.current) setSearching(false);
    }
  }
  function jump() {
    if (!doc) return;
    const page = Number(pageInput);
    if (Number.isFinite(page) && page >= 1)
      p.onPage(Math.min(pdf?.numPages ?? page, Math.round(page)));
    else setPageInput(String(doc.page));
  }
  return (
    <section
      className={`pane ${p.focused ? "focused" : ""}`}
      data-slot={p.slot}
      aria-label={`Pane ${p.slot + 1}`}
      onPointerDown={p.onFocus}
      onFocusCapture={p.onFocus}
      onDragOver={(e) => e.preventDefault()}
      onDrop={p.onDrop}
    >
      {doc ? (
        <>
          <header className="pane-heading">
            <span className="pane-number">{p.slot + 1}</span>
            <button
              className="document-handle"
              draggable
              onDragStart={p.onDrag}
              onClick={p.onMove}
              title="Drag to another pane or workspace. Click to move."
              aria-label={`Move ${doc.name}`}
            >
              <GripVertical size={15} />
            </button>
            <span className="pane-title" title={doc.path}>
              {doc.name}
            </span>
            <Tool
              label={p.expanded ? "Restore layout" : "Focus this pane"}
              onClick={p.onExpand}
            >
              {p.expanded ? <Minimize2 size={15} /> : <Maximize2 size={15} />}
            </Tool>
            <Tool label="Hide from pane" onClick={p.onHide}>
              <X size={16} />
            </Tool>
          </header>
          <div className="page-toolbar">
            <div className="control-cluster">
              <Tool
                label="Previous page"
                disabled={!pdf || doc.page <= 1}
                onClick={() => p.onPage(doc.page - 1)}
              >
                <ChevronLeft size={16} />
              </Tool>
              <input
                className="page-number"
                aria-label={`Page in ${doc.name}`}
                inputMode="numeric"
                value={pageInput}
                onChange={(e) => setPageInput(e.target.value)}
                onBlur={jump}
                onKeyDown={(e) => {
                  if (e.key === "Enter") jump();
                }}
              />
              <span className="page-total">/ {pdf?.numPages ?? "–"}</span>
              <Tool
                label="Next page"
                disabled={!pdf || doc.page >= pdf.numPages}
                onClick={() => p.onPage(doc.page + 1)}
              >
                <ChevronRight size={16} />
              </Tool>
            </div>
            <div className="control-cluster zoom-controls">
              <Tool
                label="Zoom out"
                disabled={!pdf}
                onClick={() =>
                  p.onPatch({
                    fit: "manual",
                    zoom: Math.max(0.25, scale / 1.2),
                  })
                }
              >
                <Minus size={15} />
              </Tool>
              <button
                className="zoom-label"
                title="Reset to 100%"
                onClick={() => p.onPatch({ fit: "manual", zoom: 1 })}
              >
                {Math.round(scale * 100)}%
              </button>
              <Tool
                label="Zoom in"
                disabled={!pdf}
                onClick={() =>
                  p.onPatch({ fit: "manual", zoom: Math.min(4, scale * 1.2) })
                }
              >
                <Plus size={15} />
              </Tool>
            </div>
            <div className="control-cluster view-controls">
              <Tool
                label="Fit page"
                aria-pressed={doc.fit === "page"}
                onClick={() => p.onPatch({ fit: "page" })}
              >
                <Scan size={16} />
              </Tool>
              <Tool
                label="Fit width"
                aria-pressed={doc.fit === "width"}
                onClick={() => p.onPatch({ fit: "width" })}
              >
                <MoveHorizontal size={16} />
              </Tool>
              <Tool
                label="Rotate clockwise"
                onClick={() =>
                  p.onPatch({ rotation: (doc.rotation + 90) % 360 })
                }
              >
                <RotateCw size={15} />
              </Tool>
              <Tool
                label="Find text"
                aria-pressed={searchOpen}
                onClick={() => setSearchOpen(!searchOpen)}
              >
                <Search size={15} />
              </Tool>
            </div>
          </div>
          {searchOpen && (
            <form
              className="search-bar"
              onSubmit={(e) => {
                e.preventDefault();
                void find();
              }}
            >
              <input
                aria-label="Search this PDF"
                placeholder="Find text in this PDF"
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value);
                  searchGeneration.current++;
                  setSearching(false);
                  setSearched(false);
                  setHits([]);
                }}
              />
              <button disabled={searching || !query.trim()}>
                {searching ? "Finding…" : "Find"}
              </button>
              {searched &&
                (hits.length ? (
                  <select
                    aria-label="Matching pages"
                    value={hits.includes(doc.page) ? doc.page : hits[0]}
                    onChange={(e) => p.onPage(Number(e.target.value))}
                  >
                    {hits.map((n) => (
                      <option key={n} value={n}>
                        Page {n}
                      </option>
                    ))}
                  </select>
                ) : (
                  <span>No text found</span>
                ))}
            </form>
          )}
          <div className="page-scroll" ref={body}>
            {error ? (
              <div className="pane-message error-state">
                <strong>Couldn’t open this PDF</strong>
                <p>{error}</p>
                <button onClick={p.onOpen}>Add a PDF</button>
              </div>
            ) : unlock ? (
              <form
                className="pane-message"
                onSubmit={(e) => {
                  e.preventDefault();
                  unlock.submit(password);
                  setPassword("");
                }}
              >
                <LockKeyhole size={28} />
                <strong>Password required</strong>
                <p>
                  {unlock.wrong
                    ? "Incorrect password. Try again."
                    : "This PDF is password protected."}
                </p>
                <input
                  type="password"
                  aria-label="PDF password"
                  autoFocus
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
                <button className="primary" type="submit">
                  Unlock
                </button>
              </form>
            ) : !pdf ? (
              <div className="pane-message">
                <LoaderCircle className="spin" size={24} />
                <span>Opening PDF…</span>
              </div>
            ) : (
              <div className="sheet-wrap">
                <div className="pdf-sheet" ref={sheet} />
              </div>
            )}
          </div>
          {rendering && pdf && !error && (
            <div className="render-status">
              <LoaderCircle size={12} className="spin" /> Rendering
            </div>
          )}
        </>
      ) : (
        <div className="empty-pane">
          <div className="empty-sheet">
            <FilePlus2 size={30} strokeWidth={1.25} />
          </div>
          <h2>Add a PDF</h2>
          <p>Drop a file here, or choose one.</p>
          <button onClick={p.onOpen}>Choose PDF…</button>
          <span className="empty-pane-number">Pane {p.slot + 1}</span>
        </div>
      )}
    </section>
  );
}
