import { test, expect } from "@playwright/test";
import path from "node:path";

test("pinch retains painted canvases, anchors the pointer, and commits only at release", async ({
  page,
}, info) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await page
    .getByTestId("file-input")
    .setInputFiles([
      path.resolve("tests/fixtures/long.pdf"),
      path.resolve("tests/fixtures/answers.pdf"),
    ]);
  const pane = page.locator('[data-slot="0"]');
  await expect(pane.locator("canvas").first()).toBeVisible();
  await pane.locator(".zoom-label").click();
  const input = pane.getByRole("textbox", { name: "Page in long.pdf" });
  await input.fill("60");
  await input.press("Enter");
  const sheet = pane.locator('[data-page="60"] .pdf-sheet');
  await expect(sheet).toHaveAttribute("data-render-scale", "1");
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          JSON.parse(localStorage.getItem("folio-session")!).views[0]
            .documents[0].zoom,
      ),
    )
    .toBe(1);
  const result = await pane.evaluate(async (pane) => {
    const scroller = pane.querySelector<HTMLElement>(".page-scroll")!;
    const sheet = pane.querySelector<HTMLElement>(
      '[data-page="60"] .pdf-sheet',
    )!;
    const canvas = sheet.querySelector("canvas")!;
    const otherCanvas = document.querySelector('[data-slot="1"] canvas');
    const viewport = scroller.getBoundingClientRect();
    const initial = sheet.getBoundingClientRect();
    const clientX = viewport.left + viewport.width * 0.55;
    const clientY = viewport.top + viewport.height * 0.45;
    const anchorX = (clientX - initial.left) / initial.width;
    const anchorY = (clientY - initial.top) / initial.height;
    let replacements = 0,
      missing = 0,
      maxAnchorError = 0,
      savedDuringPinch = false;
    const observer = new MutationObserver(() => {
      if (sheet.querySelector("canvas") !== canvas) replacements++;
    });
    observer.observe(sheet, { childList: true });
    const frame = () =>
      new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    function gesture(type: string, scale: number) {
      const event = new Event(type, { bubbles: true, cancelable: true });
      Object.defineProperties(event, {
        scale: { value: scale },
        clientX: { value: clientX },
        clientY: { value: clientY },
      });
      scroller.dispatchEvent(event);
    }
    gesture("gesturestart", 1);
    for (let i = 1; i <= 36; i++) {
      // Zoom in, reverse direction, then zoom in again within the same gesture.
      const scale =
        i <= 12
          ? 1 + i * 0.05
          : i <= 24
            ? 1.6 - (i - 12) * 0.025
            : 1.3 + (i - 24) * 0.025;
      gesture("gesturechange", scale);
      await frame();
      await frame();
      const rect = sheet.getBoundingClientRect();
      maxAnchorError = Math.max(
        maxAnchorError,
        Math.abs(rect.left + anchorX * rect.width - clientX),
        Math.abs(rect.top + anchorY * rect.height - clientY),
      );
      if (
        !sheet.querySelector("canvas") ||
        pane.querySelector('[data-page="60"] .page-loading')
      )
        missing++;
      if (
        JSON.parse(localStorage.getItem("folio-session")!).views[0].documents[0]
          .zoom !== 1
      )
        savedDuringPinch = true;
    }
    const retainedUntilRelease = sheet.querySelector("canvas") === canvas;
    observer.disconnect();
    // A replacement must be fully painted, not an empty canvas inserted early.
    let emptyReplacement = false;
    const sharpObserver = new MutationObserver(() => {
      const next = sheet.querySelector("canvas");
      if (!next) {
        emptyReplacement = true;
        return;
      }
      const pixels = next
        .getContext("2d")!
        .getImageData(0, 0, next.width, next.height).data;
      let ink = 0;
      for (let i = 0; i < pixels.length; i += 4)
        if (pixels[i + 3] > 0 && pixels[i] < 200) ink++;
      if (ink < 20) emptyReplacement = true;
    });
    sharpObserver.observe(sheet, { childList: true });
    gesture("gestureend", 1.6);
    for (let i = 0; i < 120 && sheet.dataset.renderScale !== "1.6"; i++)
      await frame();
    await frame();
    sharpObserver.disconnect();
    const final = sheet.getBoundingClientRect();
    return {
      replacements,
      missing,
      maxAnchorError,
      savedDuringPinch,
      retainedUntilRelease,
      emptyReplacement,
      finalAnchorError: Math.max(
        Math.abs(final.left + anchorX * final.width - clientX),
        Math.abs(final.top + anchorY * final.height - clientY),
      ),
      otherPaneRetained:
        document.querySelector('[data-slot="1"] canvas') === otherCanvas,
    };
  });
  expect(result).toMatchObject({
    replacements: 0,
    missing: 0,
    savedDuringPinch: false,
    retainedUntilRelease: true,
    emptyReplacement: false,
    otherPaneRetained: true,
  });
  expect(result.maxAnchorError).toBeLessThan(1.5);
  expect(result.finalAnchorError).toBeLessThan(1.5);
  await expect(sheet).toHaveAttribute("data-render-scale", "1.6");
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          JSON.parse(localStorage.getItem("folio-session")!).views[0]
            .documents[0].zoom,
      ),
    )
    .toBe(1.6);
  expect(await pane.locator("canvas").count()).toBeLessThanOrEqual(6);
  await page.screenshot({
    path: `test-results/${info.project.name}-stable-pinch.png`,
  });
  expect(errors).toEqual([]);
});

test("large zoom-out keeps virtual pages and bitmap memory bounded", async ({
  page,
}) => {
  await page.goto("/");
  await page
    .getByTestId("file-input")
    .setInputFiles(path.resolve("tests/fixtures/long.pdf"));
  const pane = page.locator('[data-slot="0"]');
  await expect(pane.locator("canvas").first()).toBeVisible();
  await pane.locator(".zoom-label").click();
  const input = pane.getByRole("textbox", { name: "Page in long.pdf" });
  await input.fill("40");
  await input.press("Enter");
  await expect(pane.locator('[data-page="40"] canvas')).toBeVisible();
  async function gesture(type: string, scale: number) {
    await pane.locator(".page-scroll").evaluate(
      (el, { type, scale }) => {
        const event = new Event(type, { bubbles: true, cancelable: true });
        Object.defineProperty(event, "scale", { value: scale });
        el.dispatchEvent(event);
      },
      { type, scale },
    );
  }
  await gesture("gesturestart", 1);
  await gesture("gestureend", 4);
  await expect(pane.locator(".zoom-label")).toHaveText("400%");
  await expect(pane.locator('[data-page="40"] .pdf-sheet')).toHaveAttribute(
    "data-render-scale",
    "4",
  );
  await gesture("gesturestart", 1);
  await gesture("gesturechange", 0.0625);
  await expect(pane.locator(".zoom-label")).toHaveText("25%");
  // Newly revealed pages render small previews, not dozens of 400% bitmaps.
  await expect.poll(() => pane.locator(".page-loading").count()).toBe(0);
  const memory = await pane
    .locator("canvas")
    .evaluateAll((canvases) =>
      canvases.reduce(
        (sum, canvas) =>
          sum +
          (canvas as HTMLCanvasElement).width *
            (canvas as HTMLCanvasElement).height,
        0,
      ),
    );
  expect(memory).toBeLessThan(20_000_000);
  expect(await pane.locator("canvas").count()).toBeLessThanOrEqual(10);
  await gesture("gestureend", 0.0625);
  await expect(pane.locator('[data-page="40"] .pdf-sheet')).toHaveAttribute(
    "data-render-scale",
    "0.25",
  );
  await pane
    .getByRole("button", { name: "Rotate clockwise", exact: true })
    .click();
  const scroller = pane.locator(".page-scroll");
  await scroller.hover();
  await page.mouse.wheel(0, 500);
  await expect.poll(() => input.inputValue()).not.toBe("40");
  await expect(pane.locator('[role="alert"]')).toHaveCount(0);
});
