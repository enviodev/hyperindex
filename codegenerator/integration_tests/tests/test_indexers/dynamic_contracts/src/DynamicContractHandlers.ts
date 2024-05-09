/*
 *Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features*
 */
import {
  FuturesMarketContract,
  FuturesMarketManagerContract,
} from "../generated/src/Handlers.gen";

import {
  FuturesMarket_CacheUpdatedEntity,
  FuturesMarket_FundingRecomputedEntity,
  FuturesMarket_FuturesTrackingEntity,
  FuturesMarket_MarginTransferredEntity,
  FuturesMarket_NextPriceOrderRemovedEntity,
  FuturesMarket_NextPriceOrderSubmittedEntity,
  FuturesMarket_PositionLiquidatedEntity,
  FuturesMarket_PositionModifiedEntity,
  FuturesMarketManager_MarketAddedEntity,
  EventsSummaryEntity,
} from "../generated/src/Types.gen";

export const GLOBAL_EVENTS_SUMMARY_KEY = "GlobalEventsSummary";

const INITIAL_EVENTS_SUMMARY: EventsSummaryEntity = {
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

FuturesMarketContract.CacheUpdated.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.CacheUpdated.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_CacheUpdatedCount:
      currentSummaryEntity.futuresMarket_CacheUpdatedCount + BigInt(1),
  };

  const futuresMarket_CacheUpdatedEntity: FuturesMarket_CacheUpdatedEntity = {
    id: event.transactionHash + event.logIndex.toString(),
    name: event.params.name,
    destination: event.params.destination,
    eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
  };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_CacheUpdated.set(futuresMarket_CacheUpdatedEntity);
});
FuturesMarketContract.FundingRecomputed.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.FundingRecomputed.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_FundingRecomputedCount:
      currentSummaryEntity.futuresMarket_FundingRecomputedCount + BigInt(1),
  };

  const futuresMarket_FundingRecomputedEntity: FuturesMarket_FundingRecomputedEntity =
    {
      id: event.transactionHash + event.logIndex.toString(),
      funding: event.params.funding,
      index: event.params.index,
      timestamp: event.params.timestamp,
      eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
    };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_FundingRecomputed.set(
    futuresMarket_FundingRecomputedEntity
  );
});
FuturesMarketContract.FuturesTracking.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.FuturesTracking.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_FuturesTrackingCount:
      currentSummaryEntity.futuresMarket_FuturesTrackingCount + BigInt(1),
  };

  const futuresMarket_FuturesTrackingEntity: FuturesMarket_FuturesTrackingEntity =
    {
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
    futuresMarket_FuturesTrackingEntity
  );
});
FuturesMarketContract.MarginTransferred.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.MarginTransferred.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_MarginTransferredCount:
      currentSummaryEntity.futuresMarket_MarginTransferredCount + BigInt(1),
  };

  const futuresMarket_MarginTransferredEntity: FuturesMarket_MarginTransferredEntity =
    {
      id: event.transactionHash + event.logIndex.toString(),
      account: event.params.account,
      marginDelta: event.params.marginDelta,
      eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
    };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarket_MarginTransferred.set(
    futuresMarket_MarginTransferredEntity
  );
});
FuturesMarketContract.NextPriceOrderRemoved.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.NextPriceOrderRemoved.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_NextPriceOrderRemovedCount:
      currentSummaryEntity.futuresMarket_NextPriceOrderRemovedCount + BigInt(1),
  };

  const futuresMarket_NextPriceOrderRemovedEntity: FuturesMarket_NextPriceOrderRemovedEntity =
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
    futuresMarket_NextPriceOrderRemovedEntity
  );
});
FuturesMarketContract.NextPriceOrderSubmitted.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.NextPriceOrderSubmitted.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_NextPriceOrderSubmittedCount:
      currentSummaryEntity.futuresMarket_NextPriceOrderSubmittedCount +
      BigInt(1),
  };

  const futuresMarket_NextPriceOrderSubmittedEntity: FuturesMarket_NextPriceOrderSubmittedEntity =
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
    futuresMarket_NextPriceOrderSubmittedEntity
  );
});
FuturesMarketContract.PositionLiquidated.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.PositionLiquidated.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_PositionLiquidatedCount:
      currentSummaryEntity.futuresMarket_PositionLiquidatedCount + BigInt(1),
  };

  const futuresMarket_PositionLiquidatedEntity: FuturesMarket_PositionLiquidatedEntity =
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
    futuresMarket_PositionLiquidatedEntity
  );
});
FuturesMarketContract.PositionModified.loader(({ event, context }) => {
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketContract.PositionModified.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarket_PositionModifiedCount:
      currentSummaryEntity.futuresMarket_PositionModifiedCount + BigInt(1),
  };

  const futuresMarket_PositionModifiedEntity: FuturesMarket_PositionModifiedEntity =
    {
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
    futuresMarket_PositionModifiedEntity
  );
});

FuturesMarketManagerContract.MarketAdded.loader(({ event, context }) => {
  context.contractRegistration.addFuturesMarket(event.params.market);
  context.EventsSummary.load(GLOBAL_EVENTS_SUMMARY_KEY);
});

FuturesMarketManagerContract.MarketAdded.handler(({ event, context }) => {
  const summary = context.EventsSummary.get(GLOBAL_EVENTS_SUMMARY_KEY);

  const currentSummaryEntity: EventsSummaryEntity =
    summary ?? INITIAL_EVENTS_SUMMARY;

  const nextSummaryEntity = {
    ...currentSummaryEntity,
    futuresMarketManager_MarketAddedCount:
      currentSummaryEntity.futuresMarketManager_MarketAddedCount + BigInt(1),
  };

  const futuresMarketManager_MarketAddedEntity: FuturesMarketManager_MarketAddedEntity =
    {
      id: event.transactionHash + event.logIndex.toString(),
      market: event.params.market,
      asset: event.params.asset,
      marketKey: event.params.marketKey,
      eventsSummary: GLOBAL_EVENTS_SUMMARY_KEY,
    };

  context.EventsSummary.set(nextSummaryEntity);
  context.FuturesMarketManager_MarketAdded.set(
    futuresMarketManager_MarketAddedEntity
  );
});
