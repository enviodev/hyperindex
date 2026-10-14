import * as S from "rescript-schema";
import type { Global } from "../../index.js";

type GlobalConfig = Global extends { config: infer C } ? C : {};
type ConfigEntities<Config> = Config extends { entities: infer E extends Record<string, object> } ? E : {};
type EntityId<E> = E extends { readonly id: infer Id } ? Id : string;

export type GetWhereOperator<T> = {
  readonly _eq?: T;
  readonly _gt?: T;
  readonly _lt?: T;
  readonly _gte?: T;
  readonly _lte?: T;
  readonly _in?: readonly T[];
};
export type GetWhereFilter<E> = { readonly [K in keyof E]?: GetWhereOperator<E[K]> };
export type OrderBy<E> = { readonly [K in keyof E]?: "asc" | "desc" };
/** Entity fields to select; `id` is always selected. */
export type FieldSelection<E> = readonly (keyof E & string)[];
/** The row type for a selection: the selected fields plus `id`, or the whole entity. */
export type Projected<E, F extends FieldSelection<E> | undefined> = F extends readonly (infer K)[]
  ? Pick<E, Extract<K | "id", keyof E>>
  : E;
export type QueryOpts<E, F extends FieldSelection<E> | undefined = undefined> = {
  readonly orderBy?: OrderBy<E>;
  /** Rows per call; defaults to and is capped at the GraphQL response limit. */
  readonly limit?: number;
  readonly offset?: number;
  /** Select only these fields (plus `id`) instead of every column. */
  readonly fields?: F;
};
export type IterateOpts<E, F extends FieldSelection<E> | undefined = undefined> = {
  readonly pageSize?: number;
  readonly orderBy?: OrderBy<E>;
  /** Select only these fields (plus `id`) instead of every column. */
  readonly fields?: F;
};

export type ReadOps<E> = {
  readonly get: (id: EntityId<E>) => Promise<E | undefined>;
  readonly getOrThrow: (id: EntityId<E>, message?: string) => Promise<E>;
  /** One bounded page, never the whole table; use `iterate` for that. */
  readonly getAll: <F extends FieldSelection<E> | undefined = undefined>(
    opts?: QueryOpts<E, F>,
  ) => Promise<Projected<E, F>[]>;
  readonly getWhere: <F extends FieldSelection<E> | undefined = undefined>(
    filter: GetWhereFilter<E>,
    opts?: QueryOpts<E, F>,
  ) => Promise<Projected<E, F>[]>;
  /** Every matching row, fetched a page at a time. */
  readonly iterate: <F extends FieldSelection<E> | undefined = undefined>(
    filter?: GetWhereFilter<E>,
    opts?: IterateOpts<E, F>,
  ) => AsyncIterable<Projected<E, F>>;
};

export type ChainMeta = {
  readonly chainId: number;
  readonly progressBlock: number;
  readonly sourceBlock: number;
  readonly isReady: boolean;
  readonly readyAt: Date | undefined;
};

export type IndexerClientBase = {
  readonly meta: () => Promise<ChainMeta[]>;
  readonly query: <T = unknown>(document: string, variables?: Record<string, unknown>) => Promise<T>;
};

export type IndexerClient<Entities extends Record<string, object> = ConfigEntities<GlobalConfig>> = {
  readonly [K in keyof Entities]: ReadOps<Entities[K]>;
} & IndexerClientBase;

export type EntityMeta = {
  readonly name: string;
  readonly fields: readonly string[];
  readonly chainIdField?: string | undefined;
  /** Decodes a GraphQL row (strings for numerics) into the handler's values. */
  readonly schema?: S.Schema<unknown> | undefined;
};

/** `EntityMeta`, or the runtime's own entity config (`Config.getPgUserEntities`). */
export type EntityMetaInput = EntityMeta | { readonly name: string; readonly schema: unknown; readonly table: unknown };

export type IndexerClientOptions = {
  readonly url: string | undefined;
  readonly role?: string | undefined;
  readonly secret?: string | undefined;
  readonly responseLimit?: number;
  readonly entities?: readonly EntityMetaInput[];
  readonly fetch?: typeof fetch;
  readonly timeoutMs?: number;
};

export class IndexerClientError extends Error {
  override readonly name = "IndexerClientError";
  readonly query: string;
  readonly status: number | undefined;
  readonly graphqlErrors: readonly unknown[];
  constructor(message: string, info: { query: string; status?: number; graphqlErrors?: readonly unknown[]; cause?: unknown }) {
    super(message, info.cause === undefined ? undefined : { cause: info.cause });
    this.query = info.query;
    this.status = info.status;
    this.graphqlErrors = info.graphqlErrors ?? [];
  }
}

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

type AnyRow = Record<string, unknown>;
type AnyQueryOpts = QueryOpts<AnyRow, readonly string[] | undefined>;
// The typed surface is generic per call; inside, rows are plain records.
type AnyReadOps = {
  readonly get: (id: unknown) => Promise<AnyRow | undefined>;
  readonly getOrThrow: (id: unknown, message?: string) => Promise<AnyRow>;
  readonly getAll: (opts?: AnyQueryOpts) => Promise<AnyRow[]>;
  readonly getWhere: (filter: AnyRow, opts?: AnyQueryOpts) => Promise<AnyRow[]>;
  readonly iterate: (filter?: AnyRow, opts?: IterateOpts<AnyRow, readonly string[] | undefined>) => AsyncIterable<AnyRow>;
};

// Per-field schemas of an entity's object schema, to decode a projected row.
// `t` is what rescript-schema's `S.classify` reads (the ReScript side uses it in
// PgStorage); a schema of another shape decodes nothing and values stay raw.
const fieldSchemaCache = new WeakMap<EntityMeta, Map<string, S.Schema<unknown>>>();
const fieldSchemasOf = (meta: EntityMeta): Map<string, S.Schema<unknown>> => {
  let schemas = fieldSchemaCache.get(meta);
  if (schemas === undefined) {
    schemas = new Map();
    const tagged = (meta.schema as { t?: { TAG?: unknown; items?: unknown } } | undefined)?.t;
    if (isPlainObject(tagged) && tagged.TAG === "object" && Array.isArray(tagged.items)) {
      for (const item of tagged.items as Array<{ location: string; schema: S.Schema<unknown> }>) {
        schemas.set(item.location, item.schema);
      }
    }
    fieldSchemaCache.set(meta, schemas);
  }
  return schemas;
};

type RescriptField =
  | { TAG: "Field"; _0: { fieldName: string; isChainId: boolean; linkedEntity?: string | undefined } }
  | { TAG: "DerivedFrom" };

// `Table.getApiFieldName`: Hasura and the entity types name a reference column
// `<field>_id`; the bare field name is the relationship, which needs a selection set.
const apiFieldName = (field: { fieldName: string; linkedEntity?: string | undefined }): string =>
  field.linkedEntity === undefined || field.linkedEntity === null ? field.fieldName : `${field.fieldName}_id`;

export const toEntityMeta = (input: EntityMetaInput): EntityMeta => {
  if ("fields" in input) return input;
  const table = input.table as { fields?: RescriptField[] } | undefined;
  if (!isPlainObject(table) || !Array.isArray(table.fields)) {
    throw new Error(`Entity '${input.name}': expected EntityMeta { name, fields } or an entity config with a table`);
  }
  const fields: string[] = [];
  let chainIdField: string | undefined;
  for (const field of table.fields) {
    if (field.TAG !== "Field") continue;
    fields.push(apiFieldName(field._0));
    if (field._0.isChainId) chainIdField = field._0.fieldName;
  }
  return { name: input.name, fields, chainIdField, schema: input.schema as S.Schema<unknown> };
};

// bigint, BigDecimal and Date cross GraphQL as strings.
export const encodeValue = (value: unknown): unknown => {
  if (typeof value === "bigint") return value.toString();
  if (value instanceof Date) return value.toISOString();
  if (Array.isArray(value)) return value.map(encodeValue);
  if (isPlainObject(value)) {
    if (typeof value.toFixed === "function" && value._isBigNumber === true) {
      return (value as { toFixed: () => string }).toFixed();
    }
    const out: Record<string, unknown> = {};
    for (const [key, inner] of Object.entries(value)) out[key] = encodeValue(inner);
    return out;
  }
  return value;
};

const orderByList = (orderBy: Record<string, "asc" | "desc"> | undefined): Array<Record<string, string>> | undefined =>
  orderBy === undefined ? undefined : Object.entries(orderBy).map(([field, direction]) => ({ [field]: direction }));

const INTROSPECT = `query ($name: String!) { __type(name: $name) { fields { name type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }`;

type IntrospectedType = { kind: string; name: string | null; ofType: IntrospectedType | null };

const isScalar = (type: IntrospectedType | null): boolean => {
  let current = type;
  while (current !== null) {
    if (current.kind === "SCALAR" || current.kind === "ENUM") return true;
    if (current.kind === "OBJECT" || current.kind === "INTERFACE" || current.kind === "UNION") return false;
    current = current.ofType;
  }
  return false;
};

export function createIndexerClient<Entities extends Record<string, object> = ConfigEntities<GlobalConfig>>(
  options: IndexerClientOptions,
): IndexerClient<Entities> {
  const doFetch = options.fetch ?? fetch;
  const responseLimit = options.responseLimit ?? 1000;
  const timeoutMs = options.timeoutMs ?? 30_000;
  const declared = new Map<string, EntityMeta>();
  for (const input of options.entities ?? []) {
    const meta = toEntityMeta(input);
    declared.set(meta.name, meta);
  }
  const introspected = new Map<string, Promise<EntityMeta>>();

  const query = async <T = unknown>(document: string, variables: Record<string, unknown> = {}): Promise<T> => {
    if (options.url === undefined) {
      throw new IndexerClientError("ENVIO_GRAPHQL_URL is not set, the indexer client has no endpoint", { query: document });
    }
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (options.secret !== undefined) headers["x-hasura-admin-secret"] = options.secret;
    if (options.role !== undefined) headers["x-hasura-role"] = options.role;
    let response: Response;
    try {
      response = await doFetch(options.url, {
        method: "POST",
        headers,
        body: JSON.stringify({ query: document, variables: encodeValue(variables) }),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (cause) {
      throw new IndexerClientError(`GraphQL request failed: ${cause instanceof Error ? cause.message : String(cause)}`, {
        query: document,
        cause,
      });
    }
    let body: unknown;
    try {
      body = await response.json();
    } catch (cause) {
      throw new IndexerClientError(`GraphQL endpoint answered ${response.status} without JSON`, {
        query: document,
        status: response.status,
        cause,
      });
    }
    if (!isPlainObject(body)) {
      throw new IndexerClientError(`GraphQL endpoint answered ${response.status} with a non-object body`, {
        query: document,
        status: response.status,
      });
    }
    if (Array.isArray(body.errors) && body.errors.length > 0) {
      const first = body.errors[0] as { message?: unknown };
      throw new IndexerClientError(
        `GraphQL error: ${typeof first?.message === "string" ? first.message : JSON.stringify(first)}`,
        { query: document, status: response.status, graphqlErrors: body.errors },
      );
    }
    if (!response.ok) {
      throw new IndexerClientError(`GraphQL endpoint answered ${response.status}`, {
        query: document,
        status: response.status,
      });
    }
    return body.data as T;
  };

  const metaFor = (name: string): Promise<EntityMeta> => {
    const known = declared.get(name);
    if (known !== undefined) return Promise.resolve(known);
    if (declared.size > 0) {
      return Promise.reject(new IndexerClientError(`Unknown entity '${name}'`, { query: "" }));
    }
    let pending = introspected.get(name);
    if (pending === undefined) {
      pending = query<{ __type: { fields: Array<{ name: string; type: IntrospectedType }> } | null }>(INTROSPECT, {
        name,
      }).then((data) => {
        if (data.__type === null) {
          introspected.delete(name);
          throw new IndexerClientError(`Unknown entity '${name}' (not in the GraphQL schema)`, { query: INTROSPECT });
        }
        const fields = data.__type.fields.filter((field) => isScalar(field.type)).map((field) => field.name);
        return { name, fields, chainIdField: fields.includes("chainId") ? "chainId" : undefined };
      });
      introspected.set(name, pending);
    }
    return pending;
  };

  const decode = (meta: EntityMeta, row: Record<string, unknown>): unknown => {
    if (meta.schema === undefined) return row;
    const parsed = S.parseOrThrow(row, meta.schema);
    if (meta.chainIdField !== undefined && isPlainObject(parsed) && !(meta.chainIdField in parsed)) {
      return { ...parsed, [meta.chainIdField]: row[meta.chainIdField] };
    }
    return parsed;
  };

  const decodeSelected = (meta: EntityMeta, row: Record<string, unknown>, fields: readonly string[]): Record<string, unknown> => {
    const schemas = fieldSchemasOf(meta);
    const out: Record<string, unknown> = {};
    for (const field of fields) {
      const schema = schemas.get(field);
      out[field] = schema === undefined ? row[field] : S.parseOrThrow(row[field], schema);
    }
    return out;
  };

  const decodeRow = (meta: EntityMeta, row: Record<string, unknown>, fields: readonly string[] | undefined) =>
    (fields === undefined ? decode(meta, row) : decodeSelected(meta, row, fields)) as Record<string, unknown>;

  // `id` always, plus the chain column when the keyset cursor needs it.
  const selectionOf = (meta: EntityMeta, fields: readonly string[] | undefined, keyset: boolean) => {
    if (fields === undefined) return { select: meta.fields, output: undefined };
    for (const field of fields) {
      if (!meta.fields.includes(field)) {
        throw new Error(`Entity \`${meta.name}\` has no field \`${field}\` to select (it has ${meta.fields.join(", ")})`);
      }
    }
    const output = [...new Set(["id", ...fields])];
    const select = keyset && meta.chainIdField !== undefined ? [...new Set([...output, meta.chainIdField])] : output;
    return { select, output };
  };

  const page = async (
    meta: EntityMeta,
    args: {
      where?: unknown;
      orderBy?: Array<Record<string, string>> | undefined;
      limit: number;
      offset?: number | undefined;
      select?: readonly string[] | undefined;
    },
  ): Promise<Record<string, unknown>[]> => {
    const document = `query ($where: ${meta.name}_bool_exp, $order_by: [${meta.name}_order_by!], $limit: Int, $offset: Int) { ${meta.name}(where: $where, order_by: $order_by, limit: $limit, offset: $offset) { ${(args.select ?? meta.fields).join(" ")} } }`;
    const data = await query<Record<string, Record<string, unknown>[]>>(document, {
      where: args.where ?? {},
      order_by: args.orderBy,
      limit: args.limit,
      offset: args.offset,
    });
    const rows = data[meta.name];
    if (!Array.isArray(rows)) {
      throw new IndexerClientError(`GraphQL answer has no '${meta.name}' list`, { query: document });
    }
    return rows;
  };

  const capLimit = (limit: number | undefined): number => {
    if (limit === undefined) return responseLimit;
    if (!Number.isInteger(limit) || limit < 0) throw new Error(`limit must be a non-negative integer, got ${limit}`);
    return Math.min(limit, responseLimit);
  };

  const opsFor = (name: string): AnyReadOps => {
    const list = async (filter: Record<string, unknown>, opts: AnyQueryOpts = {}) => {
      const meta = await metaFor(name);
      const { select, output } = selectionOf(meta, opts.fields, false);
      const rows = await page(meta, {
        where: filter,
        orderBy: orderByList(opts.orderBy as Record<string, "asc" | "desc"> | undefined),
        limit: capLimit(opts.limit),
        offset: opts.offset,
        select,
      });
      return rows.map((row) => decodeRow(meta, row, output));
    };
    const get = async (id: unknown) => {
      const meta = await metaFor(name);
      const rows = await page(meta, { where: { id: { _eq: id } }, limit: 2 });
      if (rows.length === 0) return undefined;
      if (rows.length > 1) {
        const field = meta.chainIdField ?? "chainId";
        throw new Error(
          `Entity \`${name}\` with id \`${String(id)}\` exists on multiple chains, use getWhere({ ${field}: { _eq: ... }, id: { _eq: ... } }) to pick one`,
        );
      }
      return decode(meta, rows[0] as Record<string, unknown>) as Record<string, unknown>;
    };
    return {
      get,
      getOrThrow: async (id, message) => {
        const row = await get(id);
        if (row === undefined) throw new Error(message ?? `Entity \`${name}\` with id \`${String(id)}\` not found`);
        return row;
      },
      getAll: (opts) => list({}, opts),
      getWhere: (filter, opts) => list(filter, opts),
      iterate: (filter = {}, opts = {}) => ({
        [Symbol.asyncIterator]: async function* () {
          const meta = await metaFor(name);
          const pageSize = capLimit(opts.pageSize);
          if (pageSize === 0) return;
          const orderBy = opts.orderBy as Record<string, "asc" | "desc"> | undefined;
          const { select, output } = selectionOf(meta, opts.fields, orderBy === undefined);
          if (orderBy !== undefined) {
            const order = [...(orderByList(orderBy) ?? []), { id: "asc" }];
            for (let offset = 0; ; offset += pageSize) {
              const rows = await page(meta, { where: filter, orderBy: order, limit: pageSize, offset, select });
              for (const row of rows) yield decodeRow(meta, row, output);
              if (rows.length < pageSize) return;
            }
          }
          const chainField = meta.chainIdField;
          const order = chainField === undefined ? [{ id: "asc" }] : [{ id: "asc" }, { [chainField]: "asc" }];
          let cursor: Record<string, unknown> | undefined;
          for (;;) {
            let where: unknown = filter;
            if (cursor !== undefined) {
              const after =
                chainField === undefined
                  ? { id: { _gt: cursor.id } }
                  : {
                      _or: [
                        { id: { _gt: cursor.id } },
                        { _and: [{ id: { _eq: cursor.id } }, { [chainField]: { _gt: cursor[chainField] } }] },
                      ],
                    };
              where = { _and: [filter, after] };
            }
            const rows = await page(meta, { where, orderBy: order, limit: pageSize, select });
            for (const row of rows) yield decodeRow(meta, row, output);
            if (rows.length < pageSize) return;
            cursor = rows[rows.length - 1];
          }
        },
      }),
    };
  };

  const base: IndexerClientBase = {
    query,
    meta: async () => {
      const data = await query<{ _meta: Array<Record<string, unknown>> }>(
        `query { _meta { chainId progressBlock sourceBlock readyAt isReady } }`,
      );
      return data._meta.map((row) => ({
        chainId: Number(row.chainId),
        progressBlock: Number(row.progressBlock),
        sourceBlock: Number(row.sourceBlock),
        isReady: row.isReady === true,
        readyAt: typeof row.readyAt === "string" ? new Date(row.readyAt) : undefined,
      }));
    },
  };
  const cache = new Map<string, AnyReadOps>();
  return new Proxy(base as IndexerClient<Entities>, {
    get: (target, prop, receiver) => {
      if (typeof prop !== "string" || prop in target || prop === "then") return Reflect.get(target, prop, receiver);
      let ops = cache.get(prop);
      if (ops === undefined) {
        ops = opsFor(prop);
        cache.set(prop, ops);
      }
      return ops;
    },
  });
}

type TestEntityOps = {
  get: (id: unknown) => Promise<unknown>;
  getOrThrow: (id: unknown, message?: string) => Promise<unknown>;
  getAll: () => Promise<unknown[]>;
  getWhere: (filter: unknown) => Promise<unknown[]>;
};

const compare = (a: unknown, b: unknown): number => {
  if (a === b) return 0;
  if (a === undefined || a === null) return -1;
  if (b === undefined || b === null) return 1;
  if (a instanceof Date && b instanceof Date) return a.getTime() - b.getTime();
  if (isPlainObject(a) && typeof a.comparedTo === "function") {
    return (a as { comparedTo: (other: unknown) => number }).comparedTo(b);
  }
  return (a as number) < (b as number) ? -1 : 1;
};

/** The read client's shape over a `createTestIndexer()`, so sidecar functions
 * unit test with no HTTP. */
export function testIndexerClient<Entities extends Record<string, object> = ConfigEntities<GlobalConfig>>(
  testIndexer: object,
): IndexerClient<Entities> {
  const ti = testIndexer as Record<string, TestEntityOps>;
  const apply = (rows: unknown[], opts: AnyQueryOpts): unknown[] => {
    let out = [...rows];
    const orderBy = opts.orderBy as Record<string, "asc" | "desc"> | undefined;
    if (orderBy !== undefined) {
      const keys = Object.entries(orderBy);
      out.sort((a, b) => {
        for (const [field, direction] of keys) {
          const c = compare((a as Record<string, unknown>)[field], (b as Record<string, unknown>)[field]);
          if (c !== 0) return direction === "desc" ? -c : c;
        }
        return 0;
      });
    }
    const offset = opts.offset ?? 0;
    out = out.slice(offset, opts.limit === undefined ? undefined : offset + opts.limit);
    const fields = opts.fields;
    if (fields === undefined) return out;
    const output = [...new Set(["id", ...fields])];
    return out.map((row) => Object.fromEntries(output.map((field) => [field, (row as Record<string, unknown>)[field]])));
  };
  const opsFor = (name: string): AnyReadOps => {
    const entity = ti[name];
    if (entity === undefined || typeof entity.getAll !== "function") {
      throw new Error(`Test indexer has no entity '${name}'`);
    }
    return {
      get: (id) => entity.get(id) as Promise<Record<string, unknown> | undefined>,
      getOrThrow: (id, message) => entity.getOrThrow(id, message) as Promise<Record<string, unknown>>,
      getAll: async (opts = {}) => apply(await entity.getAll(), opts) as Record<string, unknown>[],
      getWhere: async (filter, opts = {}) => apply(await entity.getWhere(filter), opts) as Record<string, unknown>[],
      iterate: (filter = {}, opts = {}) => ({
        [Symbol.asyncIterator]: async function* () {
          const rows =
            Object.keys(filter).length === 0 ? await entity.getAll() : await entity.getWhere(filter);
          for (const row of apply(rows, { orderBy: opts.orderBy, fields: opts.fields })) yield row as Record<string, unknown>;
        },
      }),
    };
  };
  const base: IndexerClientBase = {
    meta: async () => [],
    query: () => Promise.reject(new Error("query() is not available on a test indexer")),
  };
  const cache = new Map<string, AnyReadOps>();
  return new Proxy(base as IndexerClient<Entities>, {
    get: (target, prop, receiver) => {
      if (typeof prop !== "string" || prop in target || prop === "then") return Reflect.get(target, prop, receiver);
      let ops = cache.get(prop);
      if (ops === undefined) {
        ops = opsFor(prop);
        cache.set(prop, ops);
      }
      return ops;
    },
  });
}
