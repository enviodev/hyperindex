import { onBlock } from "generated";

onBlock({ chain: 1, name: "BlockTracker" }, async ({ block, context }) => {
  context.BlockInfo.set({
    id: block.number.toString(),
  });
});
