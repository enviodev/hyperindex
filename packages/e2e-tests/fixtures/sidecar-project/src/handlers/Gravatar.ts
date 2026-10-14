import { indexer } from "envio";

// The indexer refuses to start with nothing to fetch.
indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async () => {});
