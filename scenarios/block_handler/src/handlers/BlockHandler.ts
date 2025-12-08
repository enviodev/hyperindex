import { onBlock } from "generated";

onBlock(
  { chain: 1, name: "BlockTracker", interval: 10 },
  async ({ block, context }) => {
    context.BlockInfo.set({
      id: block.number.toString(),
    });
  }
);
