import {
  aggregationEntity,
  bucketsBetween,
  compileAggregation,
  INTERVAL_MICROS,
  ROLLUP_STATE_ENTITY,
  rollupBucket,
  storedValue,
  type CompiledAggregation,
  type PrevState,
  type SourceFields,
} from "./aggregations.ts";
import type { Scope } from "./scope.ts";

const CLOCK_ID = "clock";
const compiledBySchema = new WeakMap<object, CompiledAggregation[]>();

function compiledFor(scope: Scope): CompiledAggregation[] {
  let compiled = compiledBySchema.get(scope.schema);
  if (!compiled) {
    compiled = scope.schema.aggregations.map((def) => {
      const declared = scope.schema.entityFieldTypes[def.source] ?? {};
      const fields: SourceFields = {
        kinds: Object.fromEntries(Object.entries(declared).map(([field, type]) => [field, type.kind])),
        refs: new Set(scope.schema.entityRefFields[def.source] ?? []),
      };
      return compileAggregation(def, fields);
    });
    compiledBySchema.set(scope.schema, compiled);
  }
  return compiled;
}

function table(scope: Scope, entity: string) {
  const accessor = scope.schema.entityAccessors[entity] ?? entity;
  const found = scope.context[accessor];
  if (!found) throw new Error(`Envio Subgraph has no table for the aggregation entity ${entity}.`);
  return found;
}

/**
 * graph-node rolls up when a block's time passes the end of the bucket the
 * previous block's time was in (`Layout::rollup`): only that first bucket can
 * hold rows, since nothing was written in between. The last block time lives in
 * an entity, so a restart or a reorg rollback finds it where it left it.
 */
export function advanceRollup(scope: Scope, now: bigint): void {
  if (scope.mode !== "handler" || scope.schema.aggregations.length === 0) return;
  const state = scope.context[ROLLUP_STATE_ENTITY];
  const stored = state.getSync(CLOCK_ID);
  // Preload drops writes, so every handler there reads the clock the last batch
  // left and would roll that bucket up again; the execute pass rolls up once.
  if (scope.context.isPreload) return;
  const last: bigint | null = stored ? BigInt(JSON.parse(stored.payload).t) : null;
  if (last !== null && now <= last) return;
  if (last !== null) {
    for (const compiled of compiledFor(scope)) {
      for (const interval of compiled.def.intervals) {
        const [bucket] = bucketsBetween(last, now, interval);
        if (bucket) rollup(scope, compiled, interval, bucket.start, bucket.end);
      }
    }
  }
  state.set({ id: CLOCK_ID, aggregation: CLOCK_ID, payload: JSON.stringify({ t: now.toString() }) });
}

function rollup(scope: Scope, compiled: CompiledAggregation, interval: string, start: bigint, end: bigint) {
  const { def } = compiled;
  const source = table(scope, def.source);
  const rows = source.getWhereSync({
    timestamp: { _gte: new Date(Number(start / 1000n)), _lt: new Date(Number(end / 1000n)) },
  });
  if (rows.length === 0) return;
  const state = scope.context[ROLLUP_STATE_ENTITY];
  const group = `${def.name}|${interval}`;
  const stateId = (dimKey: string) => `prev|${group}|${dimKey}`;
  const hasCumulative = def.aggregates.some((aggregate) => aggregate.cumulative);
  // Every group's carried values in one read: read one group at a time, the
  // sync bridge would replay the handler once per group in the bucket.
  const carried = new Map<string, PrevState>();
  if (hasCumulative) {
    for (const row of state.getWhereSync({ aggregation: { _eq: group } })) {
      carried.set(row.id, JSON.parse(row.payload) as PrevState);
    }
  }
  const target = table(scope, aggregationEntity(def.name, interval));
  const timestamp = new Date(Number(start / 1000n));
  for (const bucket of rollupBucket(compiled, rows, (dimKey) => carried.get(stateId(dimKey)) ?? null)) {
    const row: Record<string, unknown> = { id: bucket.id.toString(), timestamp, ...bucket.dimensions };
    for (const aggregate of def.aggregates) {
      row[aggregate.field] = storedValue(bucket.values[aggregate.field], aggregate.kind);
    }
    target.set(row);
    if (hasCumulative) {
      state.set({ id: stateId(bucket.dimKey), aggregation: group, payload: JSON.stringify(bucket.next) });
    }
  }
}

/**
 * graph-node's `SeqGenerator::id` for an Int8: the block number in the upper 32
 * bits and a per-block sequence below. The sequence here is the log index and
 * the position within one handler run, so a replayed handler regenerates the
 * same ids.
 */
export function timeseriesId(blockNumber: number, logIndex: number, sequence: number): string {
  return ((BigInt(blockNumber) << 32n) + BigInt((logIndex + 1) * 4096 + sequence)).toString();
}

export { INTERVAL_MICROS };
