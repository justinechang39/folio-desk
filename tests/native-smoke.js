(async () => {
  let stage = "opening PDFs";
  const invoke = window.__TAURI_INTERNALS__.invoke;
  const wait = async (fn) => {
    for (let i = 0; i < 300; i++) {
      const value = await fn();
      if (value) return value;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error(`Timed out: ${stage}`);
  };
  try {
    await wait(
      () =>
        document.querySelectorAll(".pane:has(.continuous-pages)").length ===
          2 && document.querySelectorAll(".textLayer").length >= 2,
    );
    stage = "PDF text";
    await wait(() =>
      document
        .querySelector(".textLayer")
        ?.textContent.includes("Question paper"),
    );
    const canvas = document.querySelector(".pdf-sheet > canvas");
    const pixels = canvas
      .getContext("2d")
      .getImageData(0, 0, canvas.width, canvas.height).data;
    let ink = 0;
    for (let i = 0; i < pixels.length; i += 4)
      if (pixels[i] < 200 && pixels[i + 3] > 0) ink++;
    if (ink < 500) throw new Error("Native PDF canvas is blank");
    const first = document.querySelector('[data-slot="0"]');
    const initialPage = Number(first.querySelector("input").value);
    const scroller = first.querySelector(".page-scroll");
    stage = "next page placeholder";
    const next = await wait(() =>
      first.querySelector(`[data-page="${initialPage + 1}"]`),
    );
    stage = "scroll page indicator";
    scroller.scrollTop = Number.parseFloat(next.style.top) - 24 + 30;
    await wait(
      () => Number(first.querySelector("input").value) === initialPage + 1,
    );
    stage = "saved page";
    await wait(async () => {
      const s = await invoke("load_session");
      return s?.views[0]?.documents[0]?.page === initialPage + 1;
    });
    stage = "appearance dialog";
    document.querySelector('[aria-label="Appearance"]').click();
    await wait(() => document.querySelector("dialog[open]"));
    stage = "dark appearance";
    [...document.querySelectorAll("dialog button")]
      .find((b) => b.textContent.trim() === "Dark")
      .click();
    await wait(() => document.documentElement.dataset.mode === "dark");
    stage = "saved appearance";
    await wait(async () => {
      const state = await invoke("load_session");
      return (
        state?.appearance?.mode === "dark" &&
        state?.appearance?.theme === "orange"
      );
    });
    let denied = false;
    try {
      await invoke("read_pdf", { path: "/etc/passwd" });
    } catch {
      denied = true;
    }
    if (!denied) throw new Error("Non-PDF file read was not rejected");
    await invoke("smoke_report", {
      report: JSON.stringify({
        passed: true,
        panes: 2,
        continuousScroll: true,
        savedAppearance: "orange/dark",
        inkPixels: ink,
        initialPage,
        savedPage: initialPage + 1,
        fileValidation: true,
      }),
    });
  } catch (e) {
    await invoke("smoke_report", {
      report: JSON.stringify({
        passed: false,
        error: String(e),
        mode: document.documentElement.dataset.mode,
        panes: document.querySelectorAll(".continuous-pages").length,
        canvas: document.querySelectorAll(".pdf-sheet canvas").length,
        visibleText: document.body.innerText.slice(-1500),
      }),
    });
  }
})();
