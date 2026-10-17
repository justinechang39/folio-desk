import { describe, it, expect } from "vitest";
import {
  newSession,
  newView,
  addDocuments,
  setLayout,
  assignDocument,
  moveDocument,
  restoreSession,
  changePage,
} from "../src/model";
const files = Array.from({ length: 5 }, (_, i) => ({
  name: `Paper ${i}.pdf`,
  path: `/papers/${i}.pdf`,
}));
describe("workspace operations", () => {
  it("keeps every document when shrinking and expanding layouts", () => {
    const original = addDocuments(setLayout(newView(), "grid"), files);
    const small = setLayout(original, "single");
    expect(small.documents).toHaveLength(5);
    expect(small.slots).toEqual([original.slots[0]]);
    const expanded = setLayout(small, "grid");
    expect(expanded.slots).toEqual(original.slots);
  });
  it("swaps occupied panes without duplicating or losing documents", () => {
    const v = addDocuments(newView(), files.slice(0, 2));
    expect(assignDocument(v, v.slots[0]!, 1).slots).toEqual([
      v.slots[1],
      v.slots[0],
    ]);
  });
  it("moves a document with its reading position between workspaces", () => {
    const s = newSession();
    s.views[0] = addDocuments(s.views[0], files);
    s.views[0].documents[0].page = 7;
    const dest = newView("Answers");
    s.views.push(dest);
    const doc = s.views[0].documents[0];
    const moved = moveDocument(s, s.active, dest.id, doc.id);
    expect(moved.views[0].documents).toHaveLength(4);
    expect(moved.views[0].slots[0]).toBeNull();
    expect(moved.views[1].documents[0].page).toBe(7);
    expect(moved.views[1].slots[0]).toBe(doc.id);
  });
  it("keeps displaced PDFs in the shelf when dropping onto an occupied pane", () => {
    let v = addDocuments(newView(), files);
    const old = v.slots[0];
    v = assignDocument(v, v.documents[4].id, 0);
    expect(v.documents.some((d) => d.id === old)).toBe(true);
    expect(v.documents).toHaveLength(5);
  });
  it("clamps linked page changes separately and leaves shelved PDFs alone", () => {
    let v = addDocuments(newView(), files);
    v.linked = true;
    const counts = { [v.documents[0].id]: 10, [v.documents[1].id]: 3 };
    v = changePage(v, v.documents[0].id, 8, counts);
    expect(v.documents.map((d) => d.page)).toEqual([8, 3, 1, 1, 1]);
  });
  it("deduplicates repeated imports in a workspace", () => {
    expect(
      addDocuments(newView(), [files[0], files[0]]).documents,
    ).toHaveLength(1);
  });
  it("round trips session state and repairs stale slot assignments", () => {
    const s = newSession();
    s.views[0] = addDocuments(s.views[0], files);
    expect(restoreSession(JSON.parse(JSON.stringify(s)))).toEqual(s);
    s.views[0].slots[1] = s.views[0].slots[0];
    expect(restoreSession(s).views[0].slots[1]).toBeNull();
  });
  it("rejects unknown and broken session formats", () => {
    expect(() => restoreSession({ version: 2, views: [] })).toThrow();
    const s = newSession();
    s.views.push(s.views[0]);
    expect(() => restoreSession(s)).toThrow();
  });
});
