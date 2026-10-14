// User-shaped sidecar, type checked by Types.test.ts with the project template's
// tsconfig. `@ts-expect-error` lines are the mistakes the types must catch.
import { expectType } from "ts-expect";
import { createSidecar, type SidecarCaller } from "envio/sidecar";
import contract from "./contract.js";

declare module "envio" {
  interface Global {
    config: {
      entities: {
        Swap: { readonly id: string; readonly amount: bigint; readonly usd: number | undefined };
        Token: { readonly id: string; readonly symbol: string };
      };
    };
  }
}

export default createSidecar(contract, {
  functions: {
    priceSwap: async ({ input, call, emit, indexer, log }) => {
      expectType<string>(input.swapId);
      expectType<bigint>(input.amount);
      expectType<`0x${string}`>(input.token);
      expectType<number>(call.chainId);
      expectType<string>(call.id);
      expectType<number | undefined>(call.blockTimestamp);
      // @ts-expect-error absent for block handler calls
      expectType<number>(call.blockTimestamp);
      const sent = await emit.swapPriced({ swapId: input.swapId, usd: 1 });
      expectType<string>(sent.id);
      // @ts-expect-error usd is a number
      await emit.swapPriced({ swapId: input.swapId, usd: "1" });
      // @ts-expect-error not a webhook in the contract
      await emit.nope({});
      await emit.raw("anything", { ok: true }, { chainId: 1 });
      const swap = await indexer.Swap.get(input.swapId);
      expectType<{ readonly id: string; readonly amount: bigint; readonly usd: number | undefined } | undefined>(swap);
      const whales = await indexer.Swap.getWhere({ amount: { _gt: 10n ** 18n } }, { orderBy: { amount: "desc" }, limit: 10 });
      expectType<bigint>(whales[0]!.amount);
      // @ts-expect-error bigint field filtered with a string
      await indexer.Swap.getWhere({ amount: { _gt: "1" } });
      // @ts-expect-error unknown entity
      await indexer.Pool.getAll();
      for await (const token of indexer.Token.iterate({}, { pageSize: 100 })) expectType<string>(token.symbol);
      const meta = await indexer.meta();
      expectType<number>(meta[0]!.progressBlock);
      const raw = await indexer.query<{ Swap: Array<{ id: string }> }>("query { Swap { id } }");
      expectType<string>(raw.Swap[0]!.id);
      log.info("priced", { swapId: input.swapId });
    },
    notifyUser: {
      concurrency: 2,
      run: async ({ input }) => {
        expectType<string>(input.text);
      },
    },
  },
  jobs: {
    refreshPrices: {
      every: "5m",
      run: async ({ emit, indexer }) => {
        const tokens = await indexer.Token.getAll({ limit: 100 });
        for (const token of tokens) await emit.pricesRefreshed({ token: "0xabc", usd: 1, at: Date.now() }, { chainId: 1 });
      },
    },
  },
  routes: (app) => {
    app.get("/top-traders", async (req, res) => {
      const rows = await app.indexer.Swap.getWhere({ usd: { _gt: Number(req.query.min ?? 0) } });
      res.json(rows);
    });
    app.post("/hooks/payment", async (req, res) => {
      await app.emit.raw("paymentReceived", req.body, { chainId: 1 });
      res.sendStatus(204);
    });
  },
  onRollback: async ({ chainId, rollbackToBlock }) => {
    expectType<number>(chainId + rollbackToBlock);
  },
});

// @ts-expect-error notifyUser is in the contract but not implemented
createSidecar(contract, { functions: { priceSwap: async () => {} } });

declare const caller: SidecarCaller<typeof contract>;
expectType<string>(caller.priceSwap({ swapId: "s", token: "0xabc", amount: 1n }));
// @ts-expect-error amount is a bigint
caller.priceSwap({ swapId: "s", token: "0xabc", amount: 1 });
// @ts-expect-error not a function in the contract
caller.nope({});
