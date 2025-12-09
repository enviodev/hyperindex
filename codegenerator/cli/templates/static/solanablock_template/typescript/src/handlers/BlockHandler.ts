/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { onBlock } from "generated";
import { createEffect, S } from "envio";

const blockSchema = S.schema({
  blockhash: S.string,
  blockTime: S.nullable(S.number),
  blockHeight: S.nullable(S.number),
});

const nullableBlockSchema = S.nullable(blockSchema);

const getBlockDataSchema = S.schema({
  result: S.optional(nullableBlockSchema),
  error: S.optional(S.object((ctx) => ctx.field("message", S.string))),
});

const getBlockEffect = createEffect(
  {
    name: "getBlock",
    input: { slot: S.number },
    output: nullableBlockSchema,
    rateLimit: { calls: 3, per: "second" },
  },
  async ({ input, context }) => {
    const res = await fetch(process.env.ENVIO_MAINNET_RPC_URL!, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "getBlock",
        params: [
          input.slot,
          {
            maxSupportedTransactionVersion: 1,
            transactionDetails: "none",
            encoding: "jsonParsed",
          },
        ],
      }),
    });
    let data;
    try {
      data = await res.json();
    } catch (error) {
      context.log.warn(`Failed to parse block data`);
      return undefined;
    }
    const parsedData = S.parseOrThrow(data, getBlockDataSchema);
    if (parsedData.error) {
      throw new Error(parsedData.error);
    }
    return parsedData.result;
  }
);

onBlock(
  { chain: 0, name: "BlockTracker" },
  async ({ slot, context }) => {
    const block = await context.effect(getBlockEffect, { slot });
    if (!block) {
      context.log.info(`Slot without a block`, { slot });
      return;
    }
    context.BlockInfo.set({
      id: slot.toString(),
      hash: block.blockhash,
      height: block.blockHeight,
      time: block.blockTime ? new Date(block.blockTime * 1000) : undefined,
    });
  }
);
