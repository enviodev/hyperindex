import { TestEvents, SimpleNft } from "generated";

TestEvents.IndexedBool.handler(
  async ({ context, event }) => {
    event.params;
  },
  {
    wildcard: true,
    eventFilters: [{ isTrue: true }],
  }
);

TestEvents.IndexedAddress.handler(
  async ({ context, event }) => {
    event.params;
  },
  {
    wildcard: true,
    eventFilters: [],
  }
);

SimpleNft.Transfer.handler(
  async ({ context, event }) => {
    event.params;
  },
  {
    wildcard: true,
    eventFilters: { from: [], tokenId: [] },
  }
);

SimpleNft.Erc20Transfer.handler(
  async ({ context, event }) => {
    //handler
  },
  { wildcard: true, eventFilters: { from: [] } }
);
