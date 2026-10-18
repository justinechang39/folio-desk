import { expect, test } from "vitest";
import { RenderQueue } from "../src/renderQueue";

test("render work is serial; cancelled waiting jobs never allocate; visible pages go first", async () => {
  const queue = new RenderQueue();
  const events: string[] = [];
  let finish!: () => void;
  const blocker = new Promise<void>((resolve) => {
    finish = resolve;
  });
  const active = new AbortController(),
    cancelled = new AbortController();
  queue.enqueue(async () => {
    events.push("start");
    await blocker;
    events.push("end");
  }, active.signal);
  await Promise.resolve();
  queue.enqueue(
    async () => {
      events.push("overscan");
    },
    active.signal,
    1,
  );
  queue.enqueue(async () => {
    events.push("cancelled");
  }, cancelled.signal);
  queue.enqueue(async () => {
    events.push("visible");
  }, active.signal);
  cancelled.abort();
  expect(events).toEqual(["start"]);
  finish();
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(events).toEqual(["start", "end", "visible", "overscan"]);
});
