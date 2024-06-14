/*
 *Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
 */
import {
  //contracts 
  FuturesMarket, FuturesMarketManager
  //entities
  FuturesMarket_CacheUpdated,
  FuturesMarket_FundingRecomputed,
  FuturesMarket_FuturesTracking,
  FuturesMarket_MarginTransferred,
  FuturesMarket_NextPriceOrderRemoved,
  FuturesMarket_NextPriceOrderSubmitted,
  FuturesMarket_PositionLiquidated,
  FuturesMarket_PositionModified,
  FuturesMarketManager_MarketAdded,
  EventsSummary,

} from "generated";

export const GLOBAL_EVENTS_SUMMARY_KEY = "GlobalEventsSummary";

const INITIAL_EVENTS_SUMMARY: EventsSummary = {
  id: GLOBAL_EVENTS_SUMMARY_KEY,
  futuresMarket_CacheUpdatedCount: BigInt(0),
  futuresMarket_FundingRecomputedCount: BigInt(0),
  futuresMarket_FuturesTrackingCount: BigInt(0),
  futuresMarket_MarginTransferredCount: BigInt(0),
  futuresMarket_NextPriceOrderRemovedCount: BigInt(0),
  futuresMarket_NextPriceOrderSubmittedCount: BigInt(0),
  futuresMarket_PositionLiquidatedCount: BigInt(0),
  futuresMarket_PositionModifiedCount: BigInt(0),
  futuresMarketManager_MarketAddedCount: BigInt(0),
};


FuturesMarket.CacheUpdated.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_CacheUpdatedCount:
      currentSummaryEntity.futuresMarket_CacheUpdatedCount + BigInt(1),
  };

  const futuresMarket_CacheUpdatedEntity: FuturesMarket_CacheUpdated = {
    id: event.transactionHash + event.logIndex.toString(),
    name: event.params.name,
    destination: event.params.destination,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_CacheUpdated.set(futuresMarket_CacheUpdatedEntity);
});

FuturesMarket.FundingRecomputed.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_FundingRecomputedCount:
      currentSummaryEntity.futuresMarket_FundingRecomputedCount + BigInt(1),
  };

  const futuresMarket_FundingRecomputedEntity: FuturesMarket_FundingRecomputed =
  {
    id: event.transactionHash + event.logIndex.toString(),
    funding: event.params.funding,
    index: event.params.index,
    timestamp: event.params.timestamp,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_FundingRecomputed.set(
    futuresMarket_FundingRecomputedEntity,
  );
});

FuturesMarket.FuturesTracking.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_FuturesTrackingCount:
      currentSummaryEntity.futuresMarket_FuturesTrackingCount + BigInt(1),
  };

  const futuresMarket_FuturesTrackingEntity: FuturesMarket_FuturesTracking = {
    id: event.transactionHash + event.logIndex.toString(),
    trackingCode: event.params.trackingCode,
    baseAsset: event.params.baseAsset,
    marketKey: event.params.marketKey,
    sizeDelta: event.params.sizeDelta,
    fee: event.params.fee,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_FuturesTracking.set(
    futuresMarket_FuturesTrackingEntity,
  );
});

FuturesMarket.MarginTransferred.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_MarginTransferredCount:
      currentSummaryEntity.futuresMarket_MarginTransferredCount + BigInt(1),
  };

  const futuresMarket_MarginTransferredEntity: FuturesMarket_MarginTransferred =
  {
    id: event.transactionHash + event.logIndex.toString(),
    account: event.params.account,
    marginDelta: event.params.marginDelta,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_MarginTransferred.set(
    futuresMarket_MarginTransferredEntity,
  );
});

FuturesMarket.NextPriceOrderRemoved.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_NextPriceOrderRemovedCount:
      currentSummaryEntity.futuresMarket_NextPriceOrderRemovedCount + BigInt(1),
  };

  const futuresMarket_NextPriceOrderRemovedEntity: FuturesMarket_NextPriceOrderRemoved =
  {
    id: event.transactionHash + event.logIndex.toString(),
    account: event.params.account,
    currentRoundId: event.params.currentRoundId,
    sizeDelta: event.params.sizeDelta,
    targetRoundId: event.params.targetRoundId,
    commitDeposit: event.params.commitDeposit,
    keeperDeposit: event.params.keeperDeposit,
    trackingCode: event.params.trackingCode,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_NextPriceOrderRemoved.set(
    futuresMarket_NextPriceOrderRemovedEntity,
  );
});

FuturesMarket.NextPriceOrderSubmitted.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_NextPriceOrderSubmittedCount:
      currentSummaryEntity.futuresMarket_NextPriceOrderSubmittedCount +
      BigInt(1),
  };

  const futuresMarket_NextPriceOrderSubmittedEntity: FuturesMarket_NextPriceOrderSubmitted =
  {
    id: event.transactionHash + event.logIndex.toString(),
    account: event.params.account,
    sizeDelta: event.params.sizeDelta,
    targetRoundId: event.params.targetRoundId,
    commitDeposit: event.params.commitDeposit,
    keeperDeposit: event.params.keeperDeposit,
    trackingCode: event.params.trackingCode,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_NextPriceOrderSubmitted.set(
    futuresMarket_NextPriceOrderSubmittedEntity,
  );
});

FuturesMarket.PositionLiquidated.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_PositionLiquidatedCount:
      currentSummaryEntity.futuresMarket_PositionLiquidatedCount + BigInt(1),
  };

  const futuresMarket_PositionLiquidatedEntity: FuturesMarket_PositionLiquidated =
  {
    id: event.transactionHash + event.logIndex.toString(),
    event_id: event.params.id,
    account: event.params.account,
    liquidator: event.params.liquidator,
    size: event.params.size,
    price: event.params.price,
    fee: event.params.fee,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_PositionLiquidated.set(
    futuresMarket_PositionLiquidatedEntity,
  );
});

FuturesMarket.PositionModified.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_PositionModifiedCount:
      currentSummaryEntity.futuresMarket_PositionModifiedCount + BigInt(1),
  };

  const futuresMarket_PositionModifiedEntity: FuturesMarket_PositionModified = {
    id: event.transactionHash + event.logIndex.toString(),
    event_id: event.params.id,
    account: event.params.account,
    margin: event.params.margin,
    size: event.params.size,
    tradeSize: event.params.tradeSize,
    lastPrice: event.params.lastPrice,
    fundingIndex: event.params.fundingIndex,
    fee: event.params.fee,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_PositionModified.set(
    futuresMarket_PositionModifiedEntity,
  );
});

FuturesMarketManager.MarketAdded.contractRegistration(({ event, context }) => {
  context.addFuturesMarket(event.params.market);
});

FuturesMarketManager.MarketAdded.handler(async ({ event, context }) => {
  const summary = await context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummary = summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarketManager_MarketAddedCount:
      currentSummaryEntity.futuresMarketManager_MarketAddedCount + BigInt(1),
  };

  const futuresMarketManager_MarketAddedEntity: FuturesMarketManager_MarketAdded =
  {
    id: event.transactionHash + event.logIndex.toString(),
    market: event.params.market,
    asset: event.params.asset,
    marketKey: event.params.marketKey,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarketManager_MarketAdded.set(
    futuresMarketManager_MarketAddedEntity,
  );
});
