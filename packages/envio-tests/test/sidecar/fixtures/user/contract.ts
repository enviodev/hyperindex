import { defineSidecar, S } from "envio";

export default defineSidecar({
  functions: {
    priceSwap: { input: { swapId: S.string, token: S.address, amount: S.bigint } },
    notifyUser: { input: { user: S.address, text: S.string } },
  },
  webhooks: {
    swapPriced: { body: { swapId: S.string, usd: S.number } },
    pricesRefreshed: { body: { token: S.address, usd: S.number, at: S.number } },
  },
});
