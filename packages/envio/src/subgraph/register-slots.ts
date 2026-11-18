/**
 * Bounds how many register passes run at once.
 *
 * envio's fetch loop starts a `contractRegister` for every item of a response
 * and awaits them all. A response can hold tens of thousands of items (a chain
 * kept open by a template rule is fetched far ahead of the handlers), and each
 * pass is a live mapping run with its own scope, replay rounds and pending
 * contract calls: Venus on BSC held 10,000 at once and the heap passed 4 GB
 * while the RPC answered a few calls a second. A pass now needs a slot first;
 * the rest wait as plain queue entries, which is also the back-pressure the
 * fetch loop was missing, since it awaits its passes before the next response.
 *
 * Slots go to the lowest position first, the order graph-node would process
 * them in. A pass that waits on an earlier pass (see `runRegisterRounds`) gives
 * its slot back for the wait — otherwise every slot could be held by passes
 * waiting on one that never got a slot. Waiting on an RPC answer keeps it: the
 * answer depends on nothing else here.
 */

const DEFAULT_REGISTER_CONCURRENCY = 256;

export function registerConcurrencyFromEnv(): number {
  const value = Number(process.env.ENVIO_SUBGRAPH_REGISTER_CONCURRENCY);
  return Number.isInteger(value) && value > 0 ? value : DEFAULT_REGISTER_CONCURRENCY;
}

export type RegisterSlot = {
  /** Gives the slot back while `wait` is pending and takes one again after. */
  pause<T>(wait: Promise<T>): Promise<T>;
  release(): void;
};

export type RegisterSlots = {
  acquire(position: number): Promise<RegisterSlot>;
  /** Passes holding a slot, and passes queued for one. */
  stats(): { active: number; queued: number };
};

export function createRegisterSlots(limit = registerConcurrencyFromEnv()): RegisterSlots {
  let active = 0;
  const queue: { position: number; grant: () => void }[] = [];

  const take = (position: number): Promise<void> => {
    if (active < limit && queue.length === 0) {
      active++;
      return Promise.resolve();
    }
    return new Promise<void>((grant) => {
      let at = queue.length;
      while (at > 0 && queue[at - 1].position > position) at--;
      queue.splice(at, 0, { position, grant });
    });
  };

  // A finishing pass hands its slot straight to the lowest queued position.
  const give = () => {
    const next = queue.shift();
    if (next) next.grant();
    else active--;
  };

  const slotFor = (position: number): RegisterSlot => {
    let held = true;
    return {
      async pause(wait) {
        if (!held) return wait;
        held = false;
        give();
        try {
          return await wait;
        } finally {
          await take(position);
          held = true;
        }
      },
      release() {
        if (!held) return;
        held = false;
        give();
      },
    };
  };

  return {
    async acquire(position) {
      await take(position);
      return slotFor(position);
    },
    stats: () => ({ active, queued: queue.length }),
  };
}

export const registerSlots = createRegisterSlots();
