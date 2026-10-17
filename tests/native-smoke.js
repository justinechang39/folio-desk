(async () => {
  const invoke = window.__TAURI_INTERNALS__.invoke;
  const wait = async (fn) => {
    for (let i = 0; i < 300; i++) {
      const value = await fn();
      if (value) return value;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error("Timed out waiting for native rendering");
  };
  try {
    await wait(
      () =>
        document.querySelectorAll(".pdf-sheet > canvas").length === 2 &&
        document.querySelectorAll(".textLayer").length === 2,
    );
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
    first.querySelector('[aria-label="Next page"]').click();
    await wait(
      () => Number(first.querySelector("input").value) === initialPage + 1,
    );
    await wait(async () => {
      const s = await invoke("load_session");
      return s?.views[0]?.documents[0]?.page === initialPage + 1;
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
        canvases: 2,
        inkPixels: ink,
        initialPage,
        savedPage: initialPage + 1,
        fileValidation: true,
      }),
    });
  } catch (e) {
    await invoke("smoke_report", {
      report: JSON.stringify({ passed: false, error: String(e) }),
    });
  }
})();
