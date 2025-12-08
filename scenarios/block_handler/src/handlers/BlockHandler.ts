import { onBlock } from "generated";

onBlock(
  { chain: 0, name: "BlockTracker", interval: 1 },
  async ({ block, context }) => {
    context.BlockInfo.set({
      id: block.slot.toString(),
      height: block.height,
    });
  }
);
