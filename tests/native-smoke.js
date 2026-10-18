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
    stage = "native WebKit pinch zoom";
    const otherZoom = document.querySelector(
      '[data-slot="1"] .zoom-label',
    ).textContent;
    first.querySelector(".zoom-label").click();
    await wait(() => first.querySelector(".zoom-label").textContent === "100%");
    const zoomSheet = first.querySelector(
      `[data-page="${initialPage + 1}"] .pdf-sheet`,
    );
    await wait(() => zoomSheet?.dataset.renderScale === "1");
    const zoomCanvas = zoomSheet.querySelector("canvas");
    function pinch(type, scale) {
      const event = new Event(type, { bubbles: true, cancelable: true });
      Object.defineProperty(event, "scale", { value: scale });
      scroller.dispatchEvent(event);
      if (!event.defaultPrevented) throw new Error(`Unclaimed ${type}`);
    }
    pinch("gesturestart", 1);
    pinch("gesturechange", 1.2);
    await wait(() => first.querySelector(".zoom-label").textContent === "120%");
    if (zoomSheet.querySelector("canvas") !== zoomCanvas)
      throw new Error("Native pinch replaced the displayed bitmap mid-gesture");
    pinch("gesturechange", 1.5);
    await wait(() => first.querySelector(".zoom-label").textContent === "150%");
    if (zoomSheet.querySelector("canvas") !== zoomCanvas)
      throw new Error("Native pinch replaced the displayed bitmap mid-gesture");
    pinch("gestureend", 1.5);
    await wait(() => zoomSheet.dataset.renderScale === "1.5");
    if (
      document.querySelector('[data-slot="1"] .zoom-label').textContent !==
      otherZoom
    )
      throw new Error("Pinch changed the other pane");
    await wait(
      async () =>
        (await invoke("load_session"))?.views[0]?.documents[0]?.zoom === 1.5,
    );
    stage = "repeated native zoom and bitmap retirement";
    const retired = [];
    const zoomText = zoomSheet.querySelector(".textLayer");
    const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    for (let i = 0; i < 30; i++) {
      retired.push(zoomSheet.querySelector("canvas"));
      pinch("gesturestart", 1);
      pinch("gesturechange", i % 2 ? 0.5 : 2);
      await pause(50);
      pinch("gestureend", i % 2 ? 0.5 : 2);
      await pause(i % 6 === 5 ? 350 : 200);
    }
    await wait(() => zoomSheet.dataset.renderScale === "1.5");
    await pause(300);
    const currentCanvas = zoomSheet.querySelector("canvas");
    const retainedPixels = retired
      .filter((canvas) => canvas && canvas !== currentCanvas)
      .reduce((total, canvas) => total + canvas.width * canvas.height, 0);
    if (retainedPixels !== 0)
      throw new Error(`Retired bitmaps retain ${retainedPixels} pixels`);
    if (zoomSheet.querySelector(".textLayer") !== zoomText)
      throw new Error("Zoom rebuilt the text layer");
    if (first.querySelector(".zoom-label").textContent !== "150%")
      throw new Error("Zoom controls stopped updating");
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
        syntheticPinchZoom: true,
        retainedPinchBitmap: true,
        repeatedZooms: 30,
        retiredPixels: retainedPixels,
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
        stage,
        scrollTop: document.querySelector(".page-scroll")?.scrollTop,
        currentPage: document.querySelector('[data-slot="0"] input')?.value,
        scrollSize: document.querySelector(".page-scroll")?.clientHeight,
        mode: document.documentElement.dataset.mode,
        panes: document.querySelectorAll(".continuous-pages").length,
        canvas: document.querySelectorAll(".pdf-sheet canvas").length,
        visibleText: document.body.innerText.slice(-1500),
      }),
    });
  }
})();
