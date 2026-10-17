export type Layout = "single" | "columns" | "rows" | "triple" | "grid";
export const layouts: { id: Layout; label: string; count: number }[] = [
  { id: "single", label: "Single page", count: 1 },
  { id: "columns", label: "Side by side", count: 2 },
  { id: "rows", label: "Stacked", count: 2 },
  { id: "triple", label: "Three columns", count: 3 },
  { id: "grid", label: "2 × 2", count: 4 },
];
export type Fit = "page" | "width" | "manual";
export type Doc = {
  id: string;
  path: string;
  name: string;
  page: number;
  zoom: number;
  fit: Fit;
  rotation: number;
};
export type View = {
  id: string;
  name: string;
  layout: Layout;
  documents: Doc[];
  slots: (string | null)[];
  focused: number;
  linked: boolean;
};
export type Session = {
  version: 1;
  active: string;
  views: View[];
  sidebar: boolean;
};
export const uid = () => crypto.randomUUID();
export function newView(name = "Workspace 1"): View {
  return {
    id: uid(),
    name,
    layout: "columns",
    documents: [],
    slots: [null, null],
    focused: 0,
    linked: false,
  };
}
export function newSession(): Session {
  const view = newView();
  return { version: 1, active: view.id, views: [view], sidebar: true };
}
export const paneCount = (layout: Layout) =>
  layouts.find((l) => l.id === layout)!.count;
export function setLayout(view: View, layout: Layout): View {
  const count = paneCount(layout),
    slots = view.slots.slice(0, count);
  const unused = view.documents.filter((d) => !slots.includes(d.id));
  while (slots.length < count) slots.push(unused.shift()?.id ?? null);
  return { ...view, layout, slots, focused: Math.min(view.focused, count - 1) };
}
export function addDocuments(
  view: View,
  files: { path: string; name: string }[],
  target?: number,
): View {
  const docs = [...view.documents],
    slots = [...view.slots];
  const added: string[] = [];
  for (const file of files) {
    let doc = docs.find((d) => d.path === file.path);
    if (!doc) {
      doc = { ...file, id: uid(), page: 1, zoom: 1, fit: "page", rotation: 0 };
      docs.push(doc);
    }
    if (!added.includes(doc.id)) added.push(doc.id);
  }
  let result = { ...view, documents: docs, slots };
  added.forEach((id, index) => {
    if (index === 0 && target !== undefined)
      result = assignDocument(result, id, target);
    else if (!result.slots.includes(id)) {
      const empty = result.slots.indexOf(null);
      if (empty >= 0) result = assignDocument(result, id, empty);
    }
  });
  return result;
}
export function assignDocument(view: View, id: string, slot: number): View {
  if (
    slot < 0 ||
    slot >= view.slots.length ||
    !view.documents.some((d) => d.id === id)
  )
    return view;
  const slots = [...view.slots],
    old = slots.indexOf(id),
    displaced = slots[slot];
  slots[slot] = id;
  if (old >= 0 && old !== slot) slots[old] = displaced;
  return { ...view, slots, focused: slot };
}
export function removeDocument(view: View, id: string): View {
  return {
    ...view,
    documents: view.documents.filter((d) => d.id !== id),
    slots: view.slots.map((s) => (s === id ? null : s)),
  };
}
export function moveDocument(
  session: Session,
  from: string,
  to: string,
  id: string,
  slot?: number,
): Session {
  const source = session.views.find((v) => v.id === from),
    destination = session.views.find((v) => v.id === to);
  const doc = source?.documents.find((d) => d.id === id);
  if (!source || !destination || !doc) return session;
  if (from === to)
    return {
      ...session,
      views: session.views.map((v) =>
        v.id === to ? assignDocument(v, id, slot ?? v.focused) : v,
      ),
    };
  let dest = { ...destination, documents: [...destination.documents, doc] };
  const empty = dest.slots.indexOf(null);
  if (slot !== undefined || empty >= 0)
    dest = assignDocument(dest, id, slot ?? empty);
  return {
    ...session,
    views: session.views.map((v) =>
      v.id === from ? removeDocument(v, id) : v.id === to ? dest : v,
    ),
  };
}
export function updateDocument(
  view: View,
  id: string,
  patch: Partial<Doc>,
): View {
  return {
    ...view,
    documents: view.documents.map((d) =>
      d.id === id ? { ...d, ...patch } : d,
    ),
  };
}
export function changePage(
  view: View,
  id: string,
  page: number,
  counts: Record<string, number>,
): View {
  return {
    ...view,
    documents: view.documents.map((d) =>
      d.id === id || (view.linked && view.slots.includes(d.id))
        ? {
            ...d,
            page: Math.max(
              1,
              Math.min(
                Math.round(page),
                counts[d.id] ?? Math.max(1, Math.round(page)),
              ),
            ),
          }
        : d,
    ),
  };
}
// Saved data is untrusted and may come from an older or interrupted installation.
export function restoreSession(value: unknown): Session {
  if (!value || typeof value !== "object")
    throw new Error("The saved workspace is not valid.");
  const raw = value as Partial<Session>;
  if (
    raw.version !== 1 ||
    !Array.isArray(raw.views) ||
    raw.views.length === 0 ||
    raw.views.length > 100
  )
    throw new Error("Unsupported saved workspace format.");
  const ids = new Set<string>();
  const views = raw.views.map((v): View => {
    if (
      !v ||
      typeof v.id !== "string" ||
      ids.has(v.id) ||
      typeof v.name !== "string" ||
      !layouts.some((l) => l.id === v.layout) ||
      !Array.isArray(v.documents) ||
      !Array.isArray(v.slots)
    )
      throw new Error("The saved workspace is damaged.");
    ids.add(v.id);
    const docIds = new Set<string>();
    const documents = v.documents.map((d): Doc => {
      if (
        !d ||
        typeof d.id !== "string" ||
        docIds.has(d.id) ||
        typeof d.path !== "string" ||
        typeof d.name !== "string"
      )
        throw new Error("A saved document is damaged.");
      docIds.add(d.id);
      return {
        ...d,
        page: Number.isFinite(d.page) ? Math.max(1, Math.floor(d.page)) : 1,
        zoom: Number.isFinite(d.zoom) ? Math.max(0.25, Math.min(4, d.zoom)) : 1,
        rotation: [0, 90, 180, 270].includes(d.rotation) ? d.rotation : 0,
        fit: ["page", "width", "manual"].includes(d.fit) ? d.fit : "page",
      };
    });
    const assigned = new Set<string>();
    const slots = Array.from({ length: paneCount(v.layout) }, (_, i) => {
      const id = v.slots[i];
      if (id && docIds.has(id) && !assigned.has(id)) {
        assigned.add(id);
        return id;
      }
      return null;
    });
    return {
      ...v,
      name: v.name.slice(0, 80),
      documents,
      slots,
      focused: Math.max(
        0,
        Math.min(slots.length - 1, Math.floor(v.focused) || 0),
      ),
      linked: !!v.linked,
    };
  });
  return {
    version: 1,
    views,
    active: views.some((v) => v.id === raw.active) ? raw.active! : views[0].id,
    sidebar: raw.sidebar !== false,
  };
}
