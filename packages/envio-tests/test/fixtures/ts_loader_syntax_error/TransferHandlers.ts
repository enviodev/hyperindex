import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ context }) => {
  context.Transfer.set({ id: "broken" + });
});
