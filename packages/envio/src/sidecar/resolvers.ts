/** Where a resolver's field goes: `query_root` or `mutation_root`. */
export type ResolverKind = "query" | "mutation";

/** A `resolvers:` entry from config.yaml, as the CLI normalised it. */
export type ResolverDef = {
  readonly description?: string;
  /** `kind:` in config.yaml. Absent means `"query"` (the CLI only writes it
   * for mutations, so configs without it keep their published shape). */
  readonly kind?: ResolverKind;
  readonly args: Readonly<Record<string, string>>;
  readonly output: string;
  /** `"sidecar"`, or the URL of a webhook. */
  readonly handler: string;
  readonly timeoutMs: number;
};

/** `types:`: object type name to field name to GraphQL type string. */
export type ResolverTypes = Readonly<Record<string, Readonly<Record<string, string>>>>;

/**
 * Sent by the GraphQL layer on every call so the handler can tell it apart
 * from anyone else who can reach it. `x-hasura-` prefixed on purpose: Hasura
 * strips client headers with that prefix (they become session variables), so
 * a caller can never present it themselves.
 */
export const RESOLVER_SECRET_HEADER = "x-hasura-envio-resolver-secret";

export const RESOLVER_PATH_PREFIX = "/resolvers/";

const PUBLIC_ROLE = "public";

/** Envio scalars a resolver may name that Hasura does not know without a declaration. */
const CUSTOM_SCALARS = ["BigDecimal", "BigInt"] as const;

type ActionHeader = { readonly name: string; readonly value: string } | { readonly name: string; readonly value_from_env: string };

export type HasuraAction = {
  readonly name: string;
  readonly comment?: string;
  readonly definition: {
    readonly type: ResolverKind;
    readonly kind: "synchronous";
    readonly handler: string;
    readonly arguments: ReadonlyArray<{ readonly name: string; readonly type: string }>;
    readonly output_type: string;
    /** Whole seconds, as Hasura and envio serve take it. */
    readonly timeout: number;
    readonly headers?: readonly ActionHeader[];
  };
  readonly permissions: ReadonlyArray<{ readonly role: string }>;
};

/** The `actions` and `custom_types` blocks of Hasura metadata. envio serve
 * reads the same shape from Hasura or from `ENVIO_SERVE_ACTIONS_PATH`. */
export type ResolverMetadata = {
  readonly actions: readonly HasuraAction[];
  readonly custom_types: {
    readonly scalars: ReadonlyArray<{ readonly name: string }>;
    readonly enums: readonly never[];
    readonly input_objects: readonly never[];
    readonly objects: ReadonlyArray<{
      readonly name: string;
      readonly fields: ReadonlyArray<{ readonly name: string; readonly type: string }>;
    }>;
  };
};

export type BuildOptions = {
  /** Where the GraphQL layer reaches the sidecar's public port. A `{{VAR}}`
   * template works for envio serve, which substitutes it from its own env. */
  readonly sidecarUrl: string;
  /** A literal value baked into the metadata (admin only), or an env var the
   * GraphQL layer reads it from. */
  readonly secret?: { readonly value: string } | { readonly fromEnv: string };
};

const namedType = (typeRef: string): string => typeRef.replace(/[[\]!\s]/g, "");

const byName = <T extends { readonly name: string }>(a: T, b: T) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);

const fieldsOf = (record: Readonly<Record<string, string>>) =>
  Object.entries(record)
    .map(([name, type]) => ({ name, type }))
    .sort(byName);

export function buildResolverMetadata(
  resolvers: Readonly<Record<string, ResolverDef>>,
  types: ResolverTypes,
  options: BuildOptions,
): ResolverMetadata {
  const base = options.sidecarUrl.replace(/\/+$/, "");
  const headers: ActionHeader[] | undefined =
    options.secret === undefined
      ? undefined
      : "value" in options.secret
        ? [{ name: RESOLVER_SECRET_HEADER, value: options.secret.value }]
        : [{ name: RESOLVER_SECRET_HEADER, value_from_env: options.secret.fromEnv }];

  const used = new Set<string>();
  const actions: HasuraAction[] = Object.entries(resolvers)
    .map(([name, def]): HasuraAction => {
      const args = fieldsOf(def.args);
      for (const typeRef of [def.output, ...args.map((a) => a.type)]) used.add(namedType(typeRef));
      return {
        name,
        ...(def.description === undefined ? {} : { comment: def.description }),
        definition: {
          type: def.kind ?? "query",
          kind: "synchronous",
          handler: def.handler === "sidecar" ? `${base}${RESOLVER_PATH_PREFIX}${name}` : def.handler,
          arguments: args,
          output_type: def.output,
          timeout: Math.max(1, Math.ceil(def.timeoutMs / 1000)),
          ...(headers === undefined ? {} : { headers }),
        },
        permissions: [{ role: PUBLIC_ROLE }],
      };
    })
    .sort(byName);

  const objects = Object.entries(types)
    .map(([name, fields]) => {
      const sorted = fieldsOf(fields);
      for (const field of sorted) used.add(namedType(field.type));
      return { name, fields: sorted };
    })
    .sort(byName);

  return {
    actions,
    custom_types: {
      scalars: CUSTOM_SCALARS.filter((scalar) => used.has(scalar)).map((name) => ({ name })),
      enums: [],
      input_objects: [],
      objects,
    },
  };
}

export type ApplyOptions = {
  /** Hasura's metadata endpoint, `.../v1/metadata`. */
  readonly endpoint: string;
  readonly role: string;
  readonly adminSecret: string;
  readonly metadata: ResolverMetadata;
  readonly fetch?: typeof fetch;
  readonly timeoutMs?: number;
};

/**
 * One bulk call. Meant to run right after the indexer tracks its tables, which
 * starts with `clear_metadata`: there is never an older version to reconcile,
 * and every re-initialisation puts the actions back.
 */
export async function applyResolverMetadata(options: ApplyOptions): Promise<void> {
  const { metadata } = options;
  if (metadata.actions.length === 0) return;
  const args: unknown[] = [{ type: "set_custom_types", args: metadata.custom_types }];
  for (const action of metadata.actions) {
    args.push({
      type: "create_action",
      args: {
        name: action.name,
        ...(action.comment === undefined ? {} : { comment: action.comment }),
        definition: action.definition,
      },
    });
    for (const permission of action.permissions) {
      args.push({ type: "create_action_permission", args: { action: action.name, role: permission.role } });
    }
  }
  const response = await (options.fetch ?? fetch)(options.endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-hasura-role": options.role,
      "x-hasura-admin-secret": options.adminSecret,
    },
    body: JSON.stringify({ type: "bulk", args }),
    signal: AbortSignal.timeout(options.timeoutMs ?? 30_000),
  });
  if (!response.ok) {
    throw new Error(`Applying the resolvers to Hasura failed with ${response.status}: ${await response.text()}`);
  }
}

/** Thrown by a resolver to answer with a GraphQL error the client sees as is. */
export class ResolverError extends Error {
  override readonly name = "ResolverError";
  readonly code: string;
  readonly extensions: Readonly<Record<string, unknown>>;
  constructor(message: string, options: { code?: string; extensions?: Record<string, unknown> } = {}) {
    super(message);
    this.code = options.code ?? "bad_request";
    this.extensions = options.extensions ?? {};
  }
}
