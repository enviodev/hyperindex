import { indexer, type Agent } from "envio";

// The mint is where an agent first exists and every later Transfer is the only
// source of ownership change. tokenId is the agentId.
indexer.onEvent(
  { contract: "IdentityRegistry", event: "Transfer" },
  async ({ event, context }) => {
    const id = event.params.tokenId.toString();
    const existing = await context.Agent.get(id);

    const agent: Agent = {
      id,
      agentId: event.params.tokenId,
      owner: event.params.to,
      // keep a URI that a prior Registered event may already have set
      agentURI: existing?.agentURI,
    };
    context.Agent.set(agent);
  },
);

// The ERC-8004 registration fills in the agent URI. A Transfer can arrive first
// within a block, so merge onto any existing row rather than overwrite it.
indexer.onEvent(
  { contract: "IdentityRegistry", event: "Registered" },
  async ({ event, context }) => {
    const id = event.params.agentId.toString();
    const existing = await context.Agent.get(id);

    const agent: Agent = {
      id,
      agentId: event.params.agentId,
      owner: existing?.owner ?? event.params.owner,
      // agentURI is empty when the no-argument register() overload is used
      agentURI:
        event.params.agentURI === "" ? existing?.agentURI : event.params.agentURI,
    };
    context.Agent.set(agent);
  },
);
