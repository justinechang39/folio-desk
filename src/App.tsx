import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import {
  Plus,
  X,
  FolderOpen,
  PanelLeft,
  Columns2,
  Rows2,
  Grid2X2,
  Square,
  Columns3,
  Link2,
  HelpCircle,
  FileText,
  MoreHorizontal,
  Pencil,
  ArrowRightLeft,
  Trash2,
  Check,
  AlertCircle,
  BookOpen,
  Palette,
  Sun,
  Moon,
  Monitor,
} from "lucide-react";
import PdfPane, { Tool } from "./PdfPane";
import {
  addDocuments,
  assignDocument,
  changePage,
  scrollDocument,
  layouts,
  moveDocument,
  newSession,
  newView,
  removeDocument,
  restoreSession,
  setLayout,
  updateDocument,
  type Doc,
  type Session,
  type View,
} from "./model";
import {
  archiveSession,
  browserImport,
  flushSaves,
  importPaths,
  loadSession,
  native,
  pickPdfs,
  saveSession,
  type Imports,
} from "./bridge";
import { themes, themeVariables, type Mode } from "./themes";
const layoutIcons = {
  single: Square,
  columns: Columns2,
  rows: Rows2,
  triple: Columns3,
  grid: Grid2X2,
};
type Dialog =
  | { kind: "rename"; view: string }
  | { kind: "close"; view: string }
  | { kind: "move"; view: string; doc: string }
  | { kind: "help" }
  | { kind: "appearance" }
  | null;
export default function App() {
  const [session, setSession] = useState<Session>(newSession),
    [ready, setReady] = useState(false),
    [loadError, setLoadError] = useState("");
  const [notice, setNotice] = useState(""),
    [saveError, setSaveError] = useState(""),
    [dialog, setDialog] = useState<Dialog>(null),
    [dialogText, setDialogText] = useState(""),
    [moveTarget, setMoveTarget] = useState("");
  const [expanded, setExpanded] = useState<number | null>(null),
    [dropHover, setDropHover] = useState(false),
    [importing, setImporting] = useState(false);
  const [, setCountTick] = useState(0);
  const [systemDark, setSystemDark] = useState(
    () => matchMedia("(prefers-color-scheme: dark)").matches,
  );
  const resolvedMode =
    session.appearance.mode === "system"
      ? systemDark
        ? "dark"
        : "light"
      : session.appearance.mode;
  useEffect(() => {
    const media = matchMedia("(prefers-color-scheme: dark)");
    const changed = () => setSystemDark(media.matches);
    media.addEventListener("change", changed);
    return () => media.removeEventListener("change", changed);
  }, []);
  useEffect(() => {
    const root = document.documentElement;
    root.dataset.mode = resolvedMode;
    root.dataset.theme = session.appearance.theme;
    root.style.colorScheme = resolvedMode;
    for (const [key, value] of Object.entries(
      themeVariables(session.appearance, systemDark),
    ))
      root.style.setProperty(key, value);
  }, [session.appearance, systemDark, resolvedMode]);
  useEffect(() => {
    if (native && ready)
      void getCurrentWindow()
        .setTheme(
          session.appearance.mode === "system" ? null : session.appearance.mode,
        )
        .catch(() => {});
  }, [session.appearance.mode, ready]);
  const scales = useRef<Record<string, number>>({});
  const input = useRef<HTMLInputElement>(null),
    targetSlot = useRef<number | undefined>(undefined),
    counts = useRef<Record<string, number>>({});
  const current = useRef(session);
  current.current = session;
  const actions = useRef({
    open: (_slot?: number) => {},
    newTab: () => {},
    closeTab: () => {},
    quit: async () => {},
  });
  const view = session.views.find((v) => v.id === session.active)!;
  const dialogRef = useRef<HTMLDialogElement>(null);
  function editView(fn: (v: View) => View, id?: string) {
    setSession((s) => ({
      ...s,
      views: s.views.map((v) => (v.id === (id ?? s.active) ? fn(v) : v)),
    }));
  }
  function focus(slot: number) {
    if (view.focused !== slot) editView((v) => ({ ...v, focused: slot }));
  }
  function newTab() {
    const v = newView(`Workspace ${current.current.views.length + 1}`);
    setSession((s) => ({ ...s, active: v.id, views: [...s.views, v] }));
    setExpanded(null);
  }
  function closeTab(id = current.current.active) {
    const v = current.current.views.find((v) => v.id === id)!;
    if (v.documents.length) setDialog({ kind: "close", view: id });
    else removeView(id);
  }
  function removeView(id: string) {
    setSession((s) => {
      const views = s.views.filter((v) => v.id !== id);
      if (!views.length)
        return {
          ...newSession(),
          appearance: s.appearance,
          sidebar: s.sidebar,
        };
      return {
        ...s,
        views,
        active:
          s.active === id
            ? views[Math.max(0, s.views.findIndex((v) => v.id === id) - 1)].id
            : s.active,
      };
    });
    setExpanded(null);
    setDialog(null);
  }
  function accept(
    result: Imports,
    slot?: number,
    viewId = current.current.active,
  ) {
    if (result.errors.length) setNotice(result.errors.join("\n"));
    if (result.documents.length)
      editView((v) => addDocuments(v, result.documents, slot), viewId);
  }
  async function open(slot?: number) {
    if (importing) return;
    if (!native) {
      targetSlot.current = slot;
      input.current?.click();
      return;
    }
    const viewId = current.current.active;
    setImporting(true);
    try {
      accept(await pickPdfs(), slot, viewId);
    } catch (e) {
      setNotice(String(e));
    } finally {
      setImporting(false);
    }
  }
  async function paths(paths: string[], slot?: number) {
    const viewId = current.current.active;
    setImporting(true);
    try {
      accept(await importPaths(paths), slot, viewId);
    } catch (e) {
      setNotice(String(e));
    } finally {
      setImporting(false);
    }
  }
  function drag(e: React.DragEvent, doc: Doc) {
    e.dataTransfer.setData(
      "application/x-folio-document",
      JSON.stringify({ view: view.id, doc: doc.id }),
    );
    e.dataTransfer.effectAllowed = "move";
  }
  async function drop(e: React.DragEvent, viewId: string, slot?: number) {
    e.preventDefault();
    setDropHover(false);
    const payload = e.dataTransfer.getData("application/x-folio-document");
    if (payload) {
      try {
        const data = JSON.parse(payload);
        setSession((s) => moveDocument(s, data.view, viewId, data.doc, slot));
      } catch {
        /* Ignore foreign drag formats. */
      }
      return;
    }
    if (!native && e.dataTransfer.files.length)
      accept(await browserImport([...e.dataTransfer.files]), slot, viewId);
  }
  async function quit() {
    try {
      await saveSession(current.current);
      await flushSaves();
      await getCurrentWindow().destroy();
    } catch (e) {
      setSaveError(`Workspace could not be saved. ${String(e)}`);
    }
  }
  actions.current = { open, newTab, closeTab, quit };
  useEffect(() => {
    let alive = true;
    loadSession()
      .then((value) => {
        if (!alive) return;
        if (value) setSession(restoreSession(value));
        setReady(true);
      })
      .catch((e) => {
        if (alive) setLoadError(String(e));
      });
    return () => {
      alive = false;
    };
  }, []);
  useEffect(() => {
    if (ready)
      void saveSession(session)
        .then(() => setSaveError(""))
        .catch((e) => setSaveError(String(e)));
  }, [session, ready]);
  useEffect(() => {
    setExpanded(null);
  }, [session.active, view.layout]);
  useEffect(() => {
    if (dialog && !dialogRef.current?.open) dialogRef.current?.showModal();
    else if (!dialog) dialogRef.current?.close();
  }, [dialog]);
  useEffect(() => {
    if (!native || !ready) return;
    let disposed = false;
    const cleanups: (() => void)[] = [];
    const register = async (promise: Promise<() => void>) => {
      const off = await promise;
      if (disposed) off();
      else cleanups.push(off);
    };
    async function pending() {
      try {
        const pending = await invoke<string[]>("take_pending");
        if (pending.length) await paths(pending);
      } catch (e) {
        setNotice(String(e));
      }
    }
    void register(
      listen<string>("menu-action", (e) => {
        switch (e.payload) {
          case "open":
            actions.current.open();
            break;
          case "new-view":
            actions.current.newTab();
            break;
          case "close-view":
            actions.current.closeTab();
            break;
          case "quit":
            void actions.current.quit();
            break;
        }
      }),
    );
    void register(
      listen("open-pdfs", () => {
        void pending();
      }),
    ).then(() => pending());
    void register(
      getCurrentWebview().onDragDropEvent((e) => {
        if (e.payload.type === "enter" || e.payload.type === "over")
          setDropHover(true);
        else if (e.payload.type === "leave") setDropHover(false);
        else if (e.payload.type === "drop") {
          setDropHover(false);
          const { x, y } = e.payload.position;
          const ratio = window.devicePixelRatio || 1;
          const target = document
            .elementFromPoint(x / ratio, y / ratio)
            ?.closest<HTMLElement>("[data-slot]");
          void paths(
            e.payload.paths,
            target ? Number(target.dataset.slot) : undefined,
          );
        }
      }),
    );
    void register(
      getCurrentWindow().onCloseRequested(async (e) => {
        e.preventDefault();
        await actions.current.quit();
      }),
    );
    return () => {
      disposed = true;
      cleanups.forEach((fn) => fn());
    };
  }, [ready]);
  useEffect(() => {
    function key(e: KeyboardEvent) {
      if (dialog || !ready) return;
      const input = (e.target as HTMLElement).closest(
        'input,textarea,select,[contenteditable="true"]',
      );
      const cmd = e.metaKey || e.ctrlKey;
      if (!native && cmd && e.key.toLowerCase() === "o") {
        e.preventDefault();
        void open();
        return;
      }
      if (!native && cmd && e.key.toLowerCase() === "t") {
        e.preventDefault();
        newTab();
        return;
      }
      if (!native && cmd && e.key.toLowerCase() === "w") {
        e.preventDefault();
        closeTab();
        return;
      }
      if (input) return;
      const doc = view.documents.find((d) => d.id === view.slots[view.focused]);
      if (
        doc &&
        (e.key === "ArrowRight" ||
          e.key === "PageDown" ||
          e.key === "ArrowLeft" ||
          e.key === "PageUp")
      ) {
        e.preventDefault();
        editView((v) =>
          changePage(
            v,
            doc.id,
            doc.page + (["ArrowRight", "PageDown"].includes(e.key) ? 1 : -1),
            counts.current,
          ),
        );
      } else if (doc && cmd && ["+", "=", "-", "0"].includes(e.key)) {
        e.preventDefault();
        editView((v) =>
          updateDocument(
            v,
            doc.id,
            e.key === "0"
              ? { fit: "page" }
              : {
                  fit: "manual",
                  zoom: Math.min(
                    4,
                    Math.max(
                      0.25,
                      (scales.current[doc.id] ?? doc.zoom) *
                        (e.key === "-" ? 1 / 1.2 : 1.2),
                    ),
                  ),
                },
          ),
        );
      } else if (cmd && /^[1-9]$/.test(e.key)) {
        const v = session.views[Number(e.key) - 1];
        if (v) {
          e.preventDefault();
          setSession((s) => ({ ...s, active: v.id }));
        }
      } else if (e.key === "Escape") setExpanded(null);
    }
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  });
  const moving =
    dialog?.kind === "move"
      ? session.views
          .find((v) => v.id === dialog.view)
          ?.documents.find((d) => d.id === dialog.doc)
      : undefined;
  function startMove(doc: Doc) {
    setMoveTarget(view.id);
    setDialog({ kind: "move", view: view.id, doc: doc.id });
  }
  if (loadError)
    return (
      <main className="startup">
        <AlertCircle size={32} />
        <h1>Couldn’t restore your workspace</h1>
        <p>{loadError}</p>
        <p>
          The saved session will be backed up before a fresh workspace is saved.
        </p>
        <button
          className="primary"
          onClick={async () => {
            try {
              await archiveSession();
              setLoadError("");
              setReady(true);
            } catch (e) {
              setLoadError(String(e));
            }
          }}
        >
          Start a fresh workspace
        </button>
      </main>
    );
  if (!ready)
    return (
      <main className="startup">
        <BookOpen size={32} />
        <p>Opening workspace…</p>
      </main>
    );
  return (
    <main className={dropHover ? "app external-drop" : "app"}>
      <input
        ref={input}
        type="file"
        accept="application/pdf,.pdf"
        multiple
        hidden
        data-testid="file-input"
        onChange={async (e) => {
          if (e.target.files)
            accept(
              await browserImport([...e.target.files]),
              targetSlot.current,
            );
          e.target.value = "";
        }}
      />
      <div className="tab-strip">
        <div className="brand" title="Folio Desk">
          <BookOpen size={21} />
        </div>
        <div className="tabs" role="tablist" aria-label="Workspaces">
          {session.views.map((v) => (
            <div
              className={`workspace-tab ${v.id === session.active ? "active" : ""}`}
              key={v.id}
              onDragOver={(e) => e.preventDefault()}
              onDrop={(e) => void drop(e, v.id)}
            >
              <button
                role="tab"
                aria-selected={v.id === session.active}
                onClick={() => setSession((s) => ({ ...s, active: v.id }))}
                onDoubleClick={() => {
                  setDialogText(v.name);
                  setDialog({ kind: "rename", view: v.id });
                }}
              >
                <span className="tab-mark" />
                {v.name}
                <span className="tab-count">{v.documents.length}</span>
              </button>
              <Tool label={`Close ${v.name}`} onClick={() => closeTab(v.id)}>
                <X size={13} />
              </Tool>
            </div>
          ))}
        </div>
        <Tool label="New workspace (⌘T)" onClick={newTab}>
          <Plus size={18} />
        </Tool>
        <Tool
          label="Keyboard shortcuts and help"
          onClick={() => setDialog({ kind: "help" })}
        >
          <HelpCircle size={18} />
        </Tool>
      </div>
      <div className="workspace-toolbar">
        <Tool
          label="Toggle document list"
          aria-pressed={session.sidebar}
          onClick={() => setSession((s) => ({ ...s, sidebar: !s.sidebar }))}
        >
          <PanelLeft size={18} />
        </Tool>
        <button
          className="primary add-pdfs"
          disabled={importing}
          onClick={() => void open()}
        >
          <FolderOpen size={16} />
          {importing ? "Opening…" : "Add PDFs"}
          <kbd>⌘O</kbd>
        </button>
        <span className="toolbar-divider" />
        <div className="layout-picker" aria-label="Layout">
          {layouts.map((l) => {
            const Icon = layoutIcons[l.id];
            return (
              <Tool
                key={l.id}
                label={l.label}
                aria-pressed={view.layout === l.id}
                onClick={() => editView((v) => setLayout(v, l.id))}
              >
                <Icon size={18} />
              </Tool>
            );
          })}
        </div>
        <span className="layout-label">
          {layouts.find((l) => l.id === view.layout)?.label}
        </span>
        <div className="toolbar-spacer" />
        <button
          className={`link-button ${view.linked ? "selected" : ""}`}
          aria-pressed={view.linked}
          title="Turn visible documents to the same page number. Shorter documents stop at their last page."
          onClick={() => editView((v) => ({ ...v, linked: !v.linked }))}
        >
          <Link2 size={16} />
          Link pages
        </button>
        <Tool
          label="Appearance"
          onClick={() => setDialog({ kind: "appearance" })}
        >
          <Palette size={19} />
        </Tool>
      </div>
      {(notice || saveError) && (
        <div className="notice" role="alert">
          <AlertCircle size={17} />
          <span>
            {saveError ? `Couldn’t save workspace: ${saveError}` : notice}
          </span>
          <Tool
            label="Dismiss message"
            onClick={() => {
              setNotice("");
              setSaveError("");
            }}
          >
            <X size={16} />
          </Tool>
        </div>
      )}
      <div className="work-area">
        {session.sidebar && (
          <aside className="document-list">
            <div className="list-heading">
              <span>
                Documents <small>{view.documents.length}</small>
              </span>
              <Tool
                label="Rename workspace"
                onClick={() => {
                  setDialogText(view.name);
                  setDialog({ kind: "rename", view: view.id });
                }}
              >
                <Pencil size={14} />
              </Tool>
            </div>
            <div className="document-items">
              {view.documents.map((doc) => {
                const slot = view.slots.indexOf(doc.id);
                return (
                  <div
                    className={`document-item ${view.slots[view.focused] === doc.id ? "selected" : ""}`}
                    key={doc.id}
                    draggable
                    onDragStart={(e) => drag(e, doc)}
                  >
                    <button
                      className="document-select"
                      title={doc.path}
                      onClick={() =>
                        editView((v) =>
                          slot >= 0
                            ? { ...v, focused: slot }
                            : assignDocument(v, doc.id, v.focused),
                        )
                      }
                    >
                      <FileText size={20} strokeWidth={1.5} />
                      <span>
                        <strong>{doc.name}</strong>
                        <small>
                          {slot >= 0 ? `Pane ${slot + 1}` : "In document list"}
                          {counts.current[doc.id]
                            ? ` · ${counts.current[doc.id]} pages`
                            : ""}
                        </small>
                      </span>
                    </button>
                    <Tool
                      label={`Options for ${doc.name}`}
                      onClick={() => startMove(doc)}
                    >
                      <MoreHorizontal size={17} />
                    </Tool>
                  </div>
                );
              })}
              {!view.documents.length && (
                <div className="list-empty">
                  Add PDFs to compare them in this workspace.
                </div>
              )}
            </div>
            <div className="shelf-hint">
              Drag documents between panes or onto another workspace tab.
            </div>
          </aside>
        )}
        <div
          className={`panes layout-${expanded === null ? view.layout : "single"}`}
        >
          {view.slots.map((id, slot) => {
            const doc = view.documents.find((d) => d.id === id);
            if (expanded !== null && expanded !== slot) return null;
            return (
              <PdfPane
                key={`${view.id}:${slot}:${id}`}
                doc={doc}
                slot={slot}
                focused={view.focused === slot}
                expanded={expanded === slot}
                onFocus={() => focus(slot)}
                onOpen={() => void open(slot)}
                onPatch={(patch) =>
                  doc && editView((v) => updateDocument(v, doc.id, patch))
                }
                onPage={(page) =>
                  doc &&
                  editView((v) => changePage(v, doc.id, page, counts.current))
                }
                onScrollPosition={(page, offset) =>
                  doc &&
                  editView((v) =>
                    scrollDocument(v, doc.id, page, offset, counts.current),
                  )
                }
                onCount={(count) => {
                  if (!doc) return;
                  counts.current[doc.id] = count;
                  setCountTick((t) => t + 1);
                  if (doc.page > count)
                    editView((v) => updateDocument(v, doc.id, { page: count }));
                }}
                onScale={(scale) => {
                  if (doc) scales.current[doc.id] = scale;
                }}
                onHide={() =>
                  editView((v) => ({
                    ...v,
                    slots: v.slots.map((s, i) => (i === slot ? null : s)),
                  }))
                }
                onExpand={() => {
                  focus(slot);
                  setExpanded(expanded === slot ? null : slot);
                }}
                onDrag={(e) => doc && drag(e, doc)}
                onDrop={(e) => void drop(e, view.id, slot)}
                onMove={() => doc && startMove(doc)}
              />
            );
          })}
        </div>
      </div>
      <footer className="status-bar">
        <span>Folio Desk</span>
        <span>
          {view.documents.length}{" "}
          {view.documents.length === 1 ? "document" : "documents"} in this
          workspace
        </span>
        <span className="toolbar-spacer" />
        <span>{saveError ? "Save failed" : "Workspace saved locally"}</span>
      </footer>
      <dialog
        ref={dialogRef}
        onCancel={() => setDialog(null)}
        onClick={(e) => {
          if (e.target === e.currentTarget) setDialog(null);
        }}
      >
        <div className="dialog-heading">
          <h2>
            {dialog?.kind === "rename"
              ? "Rename workspace"
              : dialog?.kind === "close"
                ? "Close workspace?"
                : dialog?.kind === "move"
                  ? "Organize document"
                  : dialog?.kind === "appearance"
                    ? "Appearance"
                    : "Using Folio Desk"}
          </h2>
          <Tool label="Close dialog" onClick={() => setDialog(null)}>
            <X size={18} />
          </Tool>
        </div>
        {dialog?.kind === "appearance" && (
          <div className="appearance-settings">
            <fieldset>
              <legend>Mode</legend>
              <div className="mode-picker">
                {(
                  [
                    { id: "system", label: "System", Icon: Monitor },
                    { id: "light", label: "Light", Icon: Sun },
                    { id: "dark", label: "Dark", Icon: Moon },
                  ] as const
                ).map(({ id, label, Icon }) => (
                  <button
                    key={id}
                    aria-pressed={session.appearance.mode === id}
                    onClick={() =>
                      setSession((s) => ({
                        ...s,
                        appearance: { ...s.appearance, mode: id as Mode },
                      }))
                    }
                  >
                    <Icon size={17} />
                    {label}
                  </button>
                ))}
              </div>
            </fieldset>
            <fieldset>
              <legend>Theme</legend>
              <div className="theme-picker">
                {themes.map((theme) => {
                  const colors = theme[resolvedMode];
                  return (
                    <button
                      key={theme.id}
                      className="theme-option"
                      aria-pressed={session.appearance.theme === theme.id}
                      onClick={() =>
                        setSession((s) => ({
                          ...s,
                          appearance: { ...s.appearance, theme: theme.id },
                        }))
                      }
                    >
                      <span
                        className="theme-preview"
                        style={{
                          background: colors.desk,
                          borderColor: colors.line,
                        }}
                      >
                        <span style={{ background: colors.surface }} />
                        <i style={{ background: colors.accent }} />
                        <span style={{ background: "#fff" }} />
                        <span style={{ background: "#fff" }} />
                      </span>
                      <span>
                        {theme.label}
                        {session.appearance.theme === theme.id && (
                          <Check size={15} />
                        )}
                      </span>
                    </button>
                  );
                })}
              </div>
            </fieldset>
            <p className="appearance-note">
              Saved automatically. PDF pages keep their original colors.
            </p>
          </div>
        )}
        {dialog?.kind === "rename" && (
          <form
            onSubmit={(e) => {
              e.preventDefault();
              if (dialogText.trim()) {
                editView(
                  (v) => ({ ...v, name: dialogText.trim().slice(0, 80) }),
                  dialog.view,
                );
                setDialog(null);
              }
            }}
          >
            <label>
              Workspace name
              <input
                autoFocus
                maxLength={80}
                value={dialogText}
                onChange={(e) => setDialogText(e.target.value)}
              />
            </label>
            <div className="dialog-actions">
              <button type="button" onClick={() => setDialog(null)}>
                Cancel
              </button>
              <button className="primary" disabled={!dialogText.trim()}>
                Save name
              </button>
            </div>
          </form>
        )}
        {dialog?.kind === "close" && (
          <>
            <p>
              Remove this workspace and its document arrangement? Your PDF files
              won’t be changed.
            </p>
            <div className="dialog-actions">
              <button onClick={() => setDialog(null)}>Keep workspace</button>
              <button
                className="danger"
                onClick={() => removeView(dialog.view)}
              >
                Close workspace
              </button>
            </div>
          </>
        )}
        {dialog?.kind === "move" && moving && (
          <>
            <p className="dialog-filename">{moving.name}</p>
            <label>
              Move to workspace
              <select
                value={moveTarget}
                onChange={(e) => setMoveTarget(e.target.value)}
              >
                {session.views.map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.name}
                  </option>
                ))}
                <option value="new">New workspace…</option>
              </select>
            </label>
            {moveTarget === dialog.view ? (
              <div className="pane-destinations">
                {view.slots.map((_, i) => (
                  <button
                    key={i}
                    onClick={() => {
                      editView((v) => assignDocument(v, moving.id, i));
                      setDialog(null);
                    }}
                  >
                    Pane {i + 1}
                    {view.slots[i] === moving.id && <Check size={14} />}
                  </button>
                ))}
              </div>
            ) : (
              <button
                className="primary full-width"
                onClick={() => {
                  const from = dialog.view,
                    id = dialog.doc;
                  if (moveTarget === "new") {
                    const v = newView(`Workspace ${session.views.length + 1}`);
                    setSession((s) =>
                      moveDocument(
                        { ...s, views: [...s.views, v], active: v.id },
                        from,
                        v.id,
                        id,
                      ),
                    );
                  } else
                    setSession((s) => moveDocument(s, from, moveTarget, id));
                  setDialog(null);
                }}
              >
                <ArrowRightLeft size={16} />
                Move document
              </button>
            )}
            <div className="dialog-actions">
              <button
                className="danger-text"
                onClick={() => {
                  editView((v) => removeDocument(v, moving.id), dialog.view);
                  setDialog(null);
                }}
              >
                <Trash2 size={15} />
                Remove from workspace
              </button>
            </div>
          </>
        )}
        {dialog?.kind === "help" && (
          <div className="help">
            <p>
              Each tab is a workspace. Add PDFs, then choose how to arrange
              them.
            </p>
            <dl>
              <dt>⌘O</dt>
              <dd>Add PDFs</dd>
              <dt>⌘T</dt>
              <dd>New workspace</dd>
              <dt>⌘W</dt>
              <dd>Close workspace</dd>
              <dt>⌘1–9</dt>
              <dd>Switch workspace</dd>
              <dt>← / →</dt>
              <dd>Turn the active PDF’s page</dd>
              <dt>⌘+ / ⌘−</dt>
              <dd>Zoom active PDF</dd>
              <dt>⌘0</dt>
              <dd>Fit page</dd>
              <dt>Esc</dt>
              <dd>Restore split layout</dd>
            </dl>
            <p>
              Drag a document by its name or grip to swap panes. Drop it on a
              workspace tab to move it there. The document’s ••• menu offers the
              same controls.
            </p>
            <p>
              Scroll each PDF independently. Link pages turns visible PDFs to
              the same page number. Search finds pages containing selectable
              text; scanned PDFs need OCR from another app.
            </p>
            <p>
              Workspaces reopen automatically. Files stay on your Mac, and
              originals are never modified.
            </p>
          </div>
        )}
      </dialog>
    </main>
  );
}
