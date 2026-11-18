import { beforeAll, describe, expect, it } from "vitest";

// envio's own TypeScript is loaded through the hooks `envio start` registers.
type Slots = typeof import("envio/src/subgraph/register-slots.ts");
let slots: Slots;
beforeAll(async () => {
  const { registerTsHooks } = await import("envio/src/HandlerLoader.res.mjs");
  registerTsHooks();
  slots = await import("envio/src/subgraph/register-slots.ts");
});

const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 5));

describe("register slots", () => {
  it("run at most the limit at once and hand a slot to the lowest position", async () => {
    const pool = slots.createRegisterSlots(2);
    const first = await pool.acquire(10);
    const second = await pool.acquire(11);
    const order: number[] = [];
    // Queued out of order: the slot goes to the lowest position, not the first asker.
    const late = pool.acquire(40).then((slot) => (order.push(40), slot));
    const early = pool.acquire(20).then((slot) => (order.push(20), slot));
    await tick();
    expect(pool.stats()).toEqual({ active: 2, queued: 2 });
    first.release();
    const earlySlot = await early;
    await tick();
    expect(order).toEqual([20]);
    second.release();
    const lateSlot = await late;
    expect(order).toEqual([20, 40]);
    earlySlot.release();
    lateSlot.release();
    expect(pool.stats()).toEqual({ active: 0, queued: 0 });
  });

  it("gives a slot back while its pass waits on an earlier one", async () => {
    // One slot: the later pass holds it and waits for the earlier pass, which
    // is queued. Without giving the slot back, neither could ever run.
    const pool = slots.createRegisterSlots(1);
    const later = await pool.acquire(50);
    let earlierRan = false;
    const earlier = pool.acquire(5).then(async (slot) => {
      earlierRan = true;
      slot.release();
    });
    const waited = later.pause(earlier);
    await waited;
    expect(earlierRan).toBe(true);
    // The later pass holds a slot again after the wait.
    expect(pool.stats()).toEqual({ active: 1, queued: 0 });
    later.release();
    later.release();
    expect(pool.stats()).toEqual({ active: 0, queued: 0 });
  });

  it("takes the slot back even when the wait fails", async () => {
    const pool = slots.createRegisterSlots(1);
    const slot = await pool.acquire(1);
    await expect(slot.pause(Promise.reject(new Error("boom")))).rejects.toThrow("boom");
    expect(pool.stats()).toEqual({ active: 1, queued: 0 });
    slot.release();
    expect(pool.stats()).toEqual({ active: 0, queued: 0 });
  });

  it("reads its default from ENVIO_SUBGRAPH_REGISTER_CONCURRENCY", () => {
    const saved = process.env.ENVIO_SUBGRAPH_REGISTER_CONCURRENCY;
    try {
      process.env.ENVIO_SUBGRAPH_REGISTER_CONCURRENCY = "7";
      expect(slots.registerConcurrencyFromEnv()).toBe(7);
      process.env.ENVIO_SUBGRAPH_REGISTER_CONCURRENCY = "nope";
      expect(slots.registerConcurrencyFromEnv()).toBe(256);
    } finally {
      if (saved === undefined) delete process.env.ENVIO_SUBGRAPH_REGISTER_CONCURRENCY;
      else process.env.ENVIO_SUBGRAPH_REGISTER_CONCURRENCY = saved;
    }
  });
});
