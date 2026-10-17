import { invoke, isTauri } from "@tauri-apps/api/core";
import type { Session } from "./model";
export const native = isTauri();
export type Imports = {
  documents: { path: string; name: string }[];
  errors: string[];
};
const browserFiles = new Map<string, File>();
export async function browserImport(files: File[]): Promise<Imports> {
  const result: Imports = { documents: [], errors: [] };
  for (const file of files) {
    if (!/\.pdf$/i.test(file.name)) {
      result.errors.push(`${file.name}: Only PDF files can be opened.`);
      continue;
    }
    if (file.size > 256 * 1024 * 1024) {
      result.errors.push(`${file.name}: This PDF exceeds the 256 MB limit.`);
      continue;
    }
    const path = `browser:${file.name}:${file.size}:${file.lastModified}`;
    browserFiles.set(path, file);
    result.documents.push({ path, name: file.name });
  }
  return result;
}
export async function readPdf(path: string): Promise<Uint8Array> {
  if (native)
    return new Uint8Array(await invoke<ArrayBuffer>("read_pdf", { path }));
  const file = browserFiles.get(path);
  if (!file)
    throw new Error(
      "Add this PDF again. Browser preview cannot reopen local files after a restart.",
    );
  return new Uint8Array(await file.arrayBuffer());
}
export const pickPdfs = () => invoke<Imports>("pick_pdfs");
export const importPaths = (paths: string[]) =>
  invoke<Imports>("import_paths", { paths });
export const loadSession = async () =>
  native
    ? invoke<unknown>("load_session")
    : JSON.parse(localStorage.getItem("folio-session") ?? "null");
let saves = Promise.resolve();
export function saveSession(session: Session): Promise<void> {
  saves = saves
    .catch(() => {})
    .then(async () => {
      if (native) await invoke("save_session", { session });
      else localStorage.setItem("folio-session", JSON.stringify(session));
    });
  return saves;
}
export const flushSaves = () => saves;

export async function archiveSession() {
  if (native) await invoke("archive_session");
  else {
    const old = localStorage.getItem("folio-session");
    if (old) localStorage.setItem(`folio-recovery-${Date.now()}`, old);
  }
}
