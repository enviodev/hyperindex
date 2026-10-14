import * as S from "rescript-schema";

// Same sugar as `createEffect`: a plain object is an object schema, an array a
// tuple, a schema is itself. Mirrors `UnknownToOutput` in index.d.ts.
type HasUndefined<T> = [T] extends [undefined] ? true : undefined extends T ? true : false;
type Flatten<T> = T extends object ? { [K in keyof T as T[K] extends never ? never : K]: T[K] } : T;
export type SchemaOutput<T> = T extends S.Schema<unknown>
  ? S.Output<T>
  : T extends (...args: unknown[]) => unknown
    ? T
    : T extends unknown[]
      ? { [K in keyof T]: SchemaOutput<T[K]> }
      : T extends { [k in keyof T]: unknown }
        ? Flatten<
            {
              [k in keyof T as HasUndefined<SchemaOutput<T[k]>> extends true ? k : never]?: SchemaOutput<T[k]>;
            } & {
              [k in keyof T as HasUndefined<SchemaOutput<T[k]>> extends true ? never : k]: SchemaOutput<T[k]>;
            }
          >
        : T;

export type SidecarFunctionDef = { readonly input: unknown };
export type SidecarWebhookDef = { readonly body: unknown };
export type SidecarContractDef = {
  readonly functions: Record<string, SidecarFunctionDef>;
  readonly webhooks?: Record<string, SidecarWebhookDef>;
};

type WebhooksOf<Def> = Def extends { readonly webhooks: infer W extends Record<string, SidecarWebhookDef> }
  ? W
  : {};
type BodyOf<W> = W extends { readonly body: infer B } ? B : never;

export type SidecarContract<Def extends SidecarContractDef = SidecarContractDef> = {
  readonly kind: "envio.sidecarContract";
  readonly functions: {
    readonly [K in keyof Def["functions"]]: {
      readonly input: S.Schema<SchemaOutput<Def["functions"][K]["input"]>>;
    };
  };
  readonly webhooks: {
    readonly [K in keyof WebhooksOf<Def>]: {
      readonly body: S.Schema<SchemaOutput<BodyOf<WebhooksOf<Def>[K]>>>;
    };
  };
};

export type SidecarFunctionName<C extends SidecarContract> = keyof C["functions"] & string;
export type SidecarWebhookName<C extends SidecarContract> = keyof C["webhooks"] & string;

export type SidecarFunctionInput<C extends SidecarContract, K extends keyof C["functions"]> =
  C["functions"][K] extends { readonly input: S.Schema<infer O> } ? O : never;
export type SidecarWebhookBody<C extends SidecarContract, K extends keyof C["webhooks"]> =
  C["webhooks"][K] extends { readonly body: S.Schema<infer O> } ? O : never;

/** The shape of `context.sidecar` in handlers: one method per contract function,
 * returning the call id synchronously. */
export type SidecarCaller<C extends SidecarContract> = {
  readonly [K in keyof C["functions"]]: (input: SidecarFunctionInput<C, K>) => string;
};

const NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
// `emit.raw` escapes the contract, so no webhook may be called that.
const RESERVED_WEBHOOK_NAMES = new Set(["raw"]);

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

// `S.schema` replaces the schema values inside the object it is handed, which
// would gut the user's declaration; it gets a copy.
const toSchema = (value: unknown): S.Schema<unknown> =>
  S.schema(isPlainObject(value) ? { ...value } : value) as S.Schema<unknown>;

const checkName = (kind: string, name: string) => {
  if (!NAME.test(name)) {
    throw new Error(
      `Sidecar ${kind} name '${name}' is invalid: use letters, digits and underscores, starting with a letter or underscore`,
    );
  }
};

export function defineSidecar<const Def extends SidecarContractDef>(def: Def): SidecarContract<Def> {
  if (!isPlainObject(def) || !isPlainObject(def.functions)) {
    throw new Error("defineSidecar expects { functions: { name: { input } }, webhooks?: { name: { body } } }");
  }
  const functions: Record<string, { input: S.Schema<unknown> }> = {};
  for (const [name, fnDef] of Object.entries(def.functions)) {
    checkName("function", name);
    if (!isPlainObject(fnDef) || !("input" in fnDef)) {
      throw new Error(`Sidecar function '${name}' needs an \`input\` schema (use S.schema(undefined) for none)`);
    }
    functions[name] = { input: toSchema(fnDef.input) };
  }
  const webhooks: Record<string, { body: S.Schema<unknown> }> = {};
  const webhookDefs = def.webhooks ?? {};
  if (!isPlainObject(webhookDefs)) {
    throw new Error("defineSidecar: `webhooks` must be an object of { name: { body } }");
  }
  for (const [name, whDef] of Object.entries(webhookDefs)) {
    checkName("webhook", name);
    if (RESERVED_WEBHOOK_NAMES.has(name)) {
      throw new Error(`Sidecar webhook name '${name}' is reserved`);
    }
    if (!isPlainObject(whDef) || !("body" in whDef)) {
      throw new Error(`Sidecar webhook '${name}' needs a \`body\` schema`);
    }
    webhooks[name] = { body: toSchema(whDef.body) };
  }
  return { kind: "envio.sidecarContract", functions, webhooks } as unknown as SidecarContract<Def>;
}

export const isSidecarContract = (value: unknown): value is SidecarContract =>
  isPlainObject(value) && value.kind === "envio.sidecarContract";
