import { indexer } from "envio";

const GLOBAL_ID = "global";

const loadGlobal = async (context: any) =>
  (await context.Global.get(GLOBAL_ID)) ?? {
    id: GLOBAL_ID,
    totalSafes: 0,
    totalSafeTransactions: 0,
    totalSuccessfulExecutions: 0,
    totalFailedExecutions: 0,
  };

indexer.contractRegister({ contract: "SafeProxyFactory130", event: "ProxyCreation" }, async ({ event, context }) => {
  context.chain.Safe130.add(event.params.proxy);
});
indexer.contractRegister({ contract: "SafeProxyFactory141", event: "ProxyCreation" }, async ({ event, context }) => {
  context.chain.Safe141.add(event.params.proxy);
});

const onProxyCreation = async ({ event, context }: any) => {
  const global = await loadGlobal(context);
  context.Global.set({ ...global, totalSafes: global.totalSafes + 1 });
  context.Safe.set({
    id: event.params.proxy,
    owners: [],
    numberOfOwners: 0,
    threshold: 0,
    numberOfSuccessfulExecutions: 0,
    numberOfFailedExecutions: 0,
    createdAt: BigInt(event.block.timestamp),
  });
};
indexer.onEvent({ contract: "SafeProxyFactory130", event: "ProxyCreation" }, onProxyCreation);
indexer.onEvent({ contract: "SafeProxyFactory141", event: "ProxyCreation" }, onProxyCreation);

const onSafeSetup = async ({ event, context }: any) => {
  const safe = await context.Safe.get(event.srcAddress);
  if (!safe) return;
  context.Safe.set({
    ...safe,
    owners: event.params.owners,
    numberOfOwners: event.params.owners.length,
    threshold: Number(event.params.threshold),
  });
};

const onExecution = (success: boolean) => async ({ event, context }: any) => {
  const [safe, global] = await Promise.all([context.Safe.get(event.srcAddress), loadGlobal(context)]);
  if (!safe) return;
  context.Safe.set({
    ...safe,
    numberOfSuccessfulExecutions: safe.numberOfSuccessfulExecutions + (success ? 1 : 0),
    numberOfFailedExecutions: safe.numberOfFailedExecutions + (success ? 0 : 1),
  });
  context.Global.set({
    ...global,
    totalSafeTransactions: global.totalSafeTransactions + 1,
    totalSuccessfulExecutions: global.totalSuccessfulExecutions + (success ? 1 : 0),
    totalFailedExecutions: global.totalFailedExecutions + (success ? 0 : 1),
  });
  context.SafeTransaction.set({
    id: `${event.transaction.hash}-${event.logIndex}`,
    safe_id: safe.id,
    txHash: event.params.txHash,
    payment: event.params.payment,
    success,
    executionDate: BigInt(event.block.timestamp),
  });
};

for (const contract of ["Safe130", "Safe141"] as const) {
  indexer.onEvent({ contract, event: "SafeSetup" }, onSafeSetup);
  indexer.onEvent({ contract, event: "ExecutionSuccess" }, onExecution(true));
  indexer.onEvent({ contract, event: "ExecutionFailure" }, onExecution(false));
}
