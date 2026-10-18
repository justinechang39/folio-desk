type Job = {
  run: () => Promise<void>;
  signal: AbortSignal;
  priority: number;
  remove: () => void;
};

// PDF.js paints on the UI thread. One job at a time leaves room for input and
// prevents each pane/overscan page from allocating a new bitmap simultaneously.
export class RenderQueue {
  private pending: Job[] = [];
  private running = false;

  enqueue(run: () => Promise<void>, signal: AbortSignal, priority = 0) {
    if (signal.aborted) return;
    const job: Job = {
      run,
      signal,
      priority,
      remove: () => {
        this.pending = this.pending.filter((candidate) => candidate !== job);
      },
    };
    signal.addEventListener("abort", job.remove, { once: true });
    this.pending.push(job);
    queueMicrotask(() => void this.drain());
  }

  private async drain() {
    if (this.running) return;
    this.running = true;
    try {
      while (this.pending.length) {
        this.pending.sort((a, b) => a.priority - b.priority);
        const job = this.pending.shift()!;
        job.signal.removeEventListener("abort", job.remove);
        if (job.signal.aborted) continue;
        // Jobs own their cancellation and error UI. Always release the slot.
        try {
          await job.run();
        } catch (error) {
          console.error("PDF render failed", error);
        }
      }
    } finally {
      this.running = false;
    }
  }
}
export const pdfRenderQueue = new RenderQueue();

export function releaseCanvas(canvas: HTMLCanvasElement | undefined) {
  // Detaching a canvas does not promptly release its backing store in WebKit.
  // Reset both dimensions, including for cancelled offscreen render targets.
  if (canvas) canvas.width = canvas.height = 0;
}
