import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "NewGravatar" }, async ({ event, context }) => {
  context.Gravatar.set({
    id: event.params.id,
    owner: event.params.owner,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
  });
});

// Reached only if the handlers load despite the type error.
throw new Error("handler loaded");
