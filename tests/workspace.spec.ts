import { test, expect } from "@playwright/test";
import path from "node:path";
const fixture = (name: string) => path.resolve("tests/fixtures", name);
test("compares, searches, zooms, swaps, moves, and preserves documents across layouts", async ({
  page,
}, testInfo) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("/");
  await page
    .getByTestId("file-input")
    .setInputFiles([
      fixture("questions.pdf"),
      fixture("answers.pdf"),
      fixture("reference.pdf"),
    ]);
  const first = page.getByRole("region", { name: "Pane 1", exact: true });
  const second = page.getByRole("region", { name: "Pane 2", exact: true });
  await expect(first.locator("canvas")).toBeVisible();
  await expect(second.locator("canvas")).toBeVisible();
  await expect(first.locator(".textLayer")).toContainText("Question paper");
  await first.getByRole("button", { name: "Next page", exact: true }).click();
  await expect(
    first.getByRole("textbox", { name: "Page in questions.pdf" }),
  ).toHaveValue("2");
  await page.getByRole("button", { name: "Link pages", exact: true }).click();
  await first.getByRole("button", { name: "Next page", exact: true }).click();
  await expect(
    second.getByRole("textbox", { name: "Page in answers.pdf" }),
  ).toHaveValue("3");
  await first.getByRole("button", { name: "Next page", exact: true }).click();
  await expect(
    second.getByRole("textbox", { name: "Page in answers.pdf" }),
  ).toHaveValue("3");
  await first.getByRole("button", { name: "Zoom in", exact: true }).click();
  await expect(
    first.getByRole("button", { name: "Fit page", exact: true }),
  ).toHaveAttribute("aria-pressed", "false");
  await first.getByRole("button", { name: "Fit page", exact: true }).click();
  await first.getByRole("button", { name: "Find text", exact: true }).click();
  await first
    .getByRole("textbox", { name: "Search this PDF" })
    .fill("momentum");
  await first.getByRole("button", { name: "Find", exact: true }).click();
  await expect(
    first.getByRole("combobox", { name: "Matching pages" }),
  ).toBeVisible();
  await expect(
    first.getByRole("combobox", { name: "Matching pages" }).locator("option"),
  ).toHaveCount(5);
  await first.getByRole("button", { name: "Find text", exact: true }).click();
  await page.getByRole("button", { name: "2 × 2", exact: true }).click();
  await expect(page.locator(".pane canvas")).toHaveCount(3);
  await page.getByRole("button", { name: "Single page", exact: true }).click();
  await expect(page.locator(".document-item")).toHaveCount(3);
  await page.getByRole("button", { name: "Side by side", exact: true }).click();
  await page
    .getByRole("button", { name: "Options for questions.pdf", exact: true })
    .click();
  await page.getByRole("button", { name: "Pane 2", exact: true }).click();
  await expect(second.locator(".pane-title")).toHaveText("questions.pdf");
  await page
    .getByRole("button", { name: "Options for reference.pdf", exact: true })
    .click();
  await page
    .getByRole("combobox", { name: "Move to workspace" })
    .selectOption("new");
  await page
    .getByRole("button", { name: "Move document", exact: true })
    .click();
  await expect(page.getByRole("tab")).toHaveCount(2);
  await expect(page.locator(".pane canvas")).toHaveCount(1);
  await page.getByRole("tab", { name: "Workspace 1" }).click();
  await expect(page.locator(".document-item")).toHaveCount(2);
  await expect(page.locator(".pane canvas")).toHaveCount(2);
  await page
    .getByRole("button", { name: "Rename workspace", exact: true })
    .click();
  await page
    .getByRole("textbox", { name: "Workspace name" })
    .fill("Physics comparison");
  await page.getByRole("button", { name: "Save name", exact: true }).click();
  await page.screenshot({
    path: `test-results/${testInfo.project.name}-workspace.png`,
  });
  await expect
    .poll(() =>
      page.evaluate(
        () => JSON.parse(localStorage.getItem("folio-session")!).views[0].name,
      ),
    )
    .toBe("Physics comparison");
  await page.reload();
  await expect(
    page.getByRole("tab", { name: "Physics comparison" }),
  ).toBeVisible();
  await expect(page.locator(".document-item")).toHaveCount(2);
  expect(errors).toEqual([]);
});
test("rejects non-PDFs and handles corrupt PDFs without losing the workspace", async ({
  page,
}) => {
  await page.goto("/");
  await page
    .getByTestId("file-input")
    .setInputFiles([fixture("notes.txt"), fixture("invalid.pdf")]);
  await expect(page.getByRole("alert")).toContainText("Only PDF files");
  await expect(page.getByText("Couldn’t open this PDF")).toBeVisible();
  await page.getByTestId("file-input").setInputFiles(fixture("questions.pdf"));
  await expect(page.locator(".pdf-sheet > canvas")).toBeVisible();
});
test("drags a document onto a pane and onto another workspace tab", async ({
  page,
}) => {
  await page.goto("/");
  await page
    .getByTestId("file-input")
    .setInputFiles([fixture("questions.pdf"), fixture("answers.pdf")]);
  await expect(page.locator(".pdf-sheet > canvas")).toHaveCount(2);
  await page
    .getByRole("button", { name: "Move questions.pdf", exact: true })
    .dragTo(page.locator('[data-slot="1"]'));
  await expect(page.locator('[data-slot="1"] .pane-title')).toHaveText(
    "questions.pdf",
  );
  await page
    .getByRole("button", { name: "New workspace (⌘T)", exact: true })
    .click();
  await page.getByRole("tab", { name: "Workspace 1" }).click();
  await page
    .getByRole("button", { name: "Move questions.pdf", exact: true })
    .dragTo(page.getByRole("tab", { name: "Workspace 2" }));
  await expect(page.locator(".document-item")).toHaveCount(1);
  await page.getByRole("tab", { name: "Workspace 2" }).click();
  await expect(page.locator(".pane-title")).toHaveText("questions.pdf");
});
test("unlocks encrypted PDFs and never saves the password", async ({
  page,
}) => {
  await page.goto("/");
  await page.getByTestId("file-input").setInputFiles(fixture("locked.pdf"));
  await expect(page.getByText("Password required")).toBeVisible();
  await page.getByRole("textbox", { name: "PDF password" }).fill("wrong");
  await page.getByRole("button", { name: "Unlock", exact: true }).click();
  await expect(page.getByText("Incorrect password. Try again.")).toBeVisible();
  await page
    .getByRole("textbox", { name: "PDF password" })
    .fill("test-password");
  await page.getByRole("button", { name: "Unlock", exact: true }).click();
  await expect(page.locator(".pdf-sheet > canvas")).toBeVisible();
  expect(
    await page.evaluate(() => localStorage.getItem("folio-session")),
  ).not.toContain("test-password");
});

test("preserves a corrupt session before starting fresh", async ({ page }) => {
  await page.addInitScript(() =>
    localStorage.setItem("folio-session", "broken-json"),
  );
  await page.goto("/");
  await expect(page.getByText("Couldn’t restore your workspace")).toBeVisible();
  await page.getByRole("button", { name: "Start a fresh workspace" }).click();
  await expect(page.getByRole("tab", { name: "Workspace 1" })).toBeVisible();
  expect(
    await page.evaluate(() =>
      Object.keys(localStorage)
        .filter((k) => k.startsWith("folio-recovery-"))
        .map((k) => localStorage.getItem(k)),
    ),
  ).toContain("broken-json");
});

test("renders every layout at the minimum window size and rotates the page", async ({
  page,
}) => {
  await page.setViewportSize({ width: 860, height: 600 });
  await page.goto("/");
  await page
    .getByTestId("file-input")
    .setInputFiles([
      fixture("questions.pdf"),
      fixture("answers.pdf"),
      fixture("reference.pdf"),
    ]);
  for (const name of ["Three columns", "Stacked", "2 × 2", "Side by side"]) {
    await page.getByRole("button", { name, exact: true }).click();
    await expect(page.locator(".pdf-sheet > canvas").first()).toBeVisible();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth),
    ).toBeLessThanOrEqual(860);
  }
  const pane = page.locator('[data-slot="0"]');
  await pane
    .getByRole("button", { name: "Rotate clockwise", exact: true })
    .click();
  await expect
    .poll(async () =>
      pane
        .locator(".pdf-sheet > canvas")
        .evaluate((c: HTMLCanvasElement) => c.width > c.height),
    )
    .toBe(true);
  await pane
    .getByRole("button", { name: "Focus this pane", exact: true })
    .click();
  await expect(page.locator(".pane")).toHaveCount(1);
  await page.keyboard.press("Escape");
  await expect(page.locator(".pane")).toHaveCount(2);
});
