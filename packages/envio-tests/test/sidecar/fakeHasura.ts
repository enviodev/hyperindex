import { createServer, type IncomingMessage, type Server } from "node:http";

export type GraphqlRequest = { readonly query: string; readonly variables: Record<string, unknown> };
export type Responder = (request: GraphqlRequest, n: number) => unknown;

/** What Hasura exposes for one tracked table: scalar columns (relations as
 * `<field>_id`), object relationships and `@derivedFrom` array relationships. */
export type HasuraType = {
  readonly columns: readonly string[];
  readonly objectRelations?: readonly string[];
  readonly arrayRelations?: readonly string[];
};

const readBody = (request: IncomingMessage): Promise<string> =>
  new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });

const scalar = (name: string) => ({ kind: "NON_NULL", name: null, ofType: { kind: "SCALAR", name, ofType: null } });

const introspect = (name: string, type: HasuraType | undefined) =>
  type === undefined
    ? { data: { __type: null } }
    : {
        data: {
          __type: {
            fields: [
              ...type.columns.map((column) => ({ name: column, type: scalar("String") })),
              ...(type.objectRelations ?? []).map((relation) => ({ name: relation, type: { kind: "OBJECT", name: relation, ofType: null } })),
              ...(type.arrayRelations ?? []).map((relation) => ({
                name: relation,
                type: { kind: "NON_NULL", name: null, ofType: { kind: "LIST", name: null, ofType: { kind: "NON_NULL", name: null, ofType: { kind: "OBJECT", name: relation, ofType: null } } } },
              })),
            ],
          },
        },
      };

// Hasura refuses a relationship selected like a column, and a field the table
// does not have: the two mistakes a typed read can make.
const selectionErrors = (query: string, types: Readonly<Record<string, HasuraType>>): string[] => {
  const errors: string[] = [];
  for (const match of query.matchAll(/(\w+)\s*\([^)]*\)\s*\{([^{}]*)\}/g)) {
    const [, root, selection] = match as unknown as [string, string, string];
    const type = types[root];
    if (type === undefined) continue;
    for (const field of selection.split(/\s+/).filter((token) => token !== "")) {
      if (type.objectRelations?.includes(field) || type.arrayRelations?.includes(field)) {
        errors.push(`missing selection set for '${field}'`);
      } else if (!type.columns.includes(field)) {
        errors.push(`field '${field}' not found in type: '${root}'`);
      }
    }
  }
  return errors;
};

const selectedFields = (query: string, root: string): string[] | undefined => {
  const match = new RegExp(`${root}\\s*\\([^)]*\\)\\s*\\{([^{}]*)\\}`).exec(query);
  return match?.[1]?.split(/\s+/).filter((token) => token !== "");
};

/** A GraphQL endpoint for the read client tests. With `types` it behaves like
 * Hasura for those tables: it refuses bad selections, answers introspection
 * the responder leaves alone, and trims answered rows to the selection. */
export const fakeGraphql = async (respond: Responder, options: { types?: Readonly<Record<string, HasuraType>> } = {}) => {
  const requests: GraphqlRequest[] = [];
  const headers: IncomingMessage["headers"][] = [];
  const types = options.types ?? {};
  const server: Server = createServer((request, response) => {
    void readBody(request).then((raw) => {
      const parsed = JSON.parse(raw) as GraphqlRequest;
      requests.push(parsed);
      headers.push(request.headers);
      const errors = selectionErrors(parsed.query, types);
      let answer: unknown;
      if (errors.length > 0) {
        answer = { errors: errors.map((message) => ({ message, extensions: { code: "validation-failed" } })) };
      } else {
        answer = respond(parsed, requests.length);
        if (answer === undefined && parsed.query.includes("__type")) {
          const name = String(parsed.variables.name);
          answer = introspect(name, types[name]);
        }
        const data = (answer as { data?: Record<string, unknown> } | undefined)?.data;
        if (data !== undefined) {
          for (const [root, rows] of Object.entries(data)) {
            const fields = types[root] === undefined ? undefined : selectedFields(parsed.query, root);
            if (fields === undefined || !Array.isArray(rows)) continue;
            data[root] = rows.map((row: Record<string, unknown>) => Object.fromEntries(fields.map((field) => [field, row[field] ?? null])));
          }
        }
      }
      const status = typeof answer === "object" && answer !== null && "__status" in answer ? (answer as { __status: number }).__status : 200;
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(answer));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  if (address === null || typeof address === "string") throw new Error("no port");
  return {
    url: `http://127.0.0.1:${address.port}/v1/graphql`,
    requests,
    headers,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
};

type Row = Record<string, unknown>;

const compare = (a: unknown, b: unknown): number => {
  if (a === b) return 0;
  if (a === null || a === undefined) return -1;
  if (b === null || b === undefined) return 1;
  const [x, y] = typeof a === "string" && /^-?\d+$/.test(a) && typeof b === "string" && /^-?\d+$/.test(b) ? [BigInt(a), BigInt(b)] : [a, b];
  return (x as number) < (y as number) ? -1 : (x as number) > (y as number) ? 1 : 0;
};

const matches = (row: Row, where: unknown): boolean => {
  if (where === null || typeof where !== "object") return true;
  return Object.entries(where as Record<string, unknown>).every(([key, condition]) => {
    if (key === "_and") return (condition as unknown[]).every((inner) => matches(row, inner));
    if (key === "_or") return (condition as unknown[]).some((inner) => matches(row, inner));
    return Object.entries(condition as Record<string, unknown>).every(([op, value]) => {
      const c = compare(row[key], value);
      switch (op) {
        case "_eq":
          return c === 0;
        case "_gt":
          return c > 0;
        case "_gte":
          return c >= 0;
        case "_lt":
          return c < 0;
        case "_lte":
          return c <= 0;
        case "_in":
          return (value as unknown[]).some((candidate) => compare(row[key], candidate) === 0);
        default:
          throw new Error(`fake Hasura has no operator ${op}`);
      }
    });
  });
};

/** Answers `<root>(where, order_by, limit, offset)` over in-memory rows the way
 * Hasura would (comparisons on numeric strings are numeric). */
export const tableResponder =
  (tables: Readonly<Record<string, readonly Row[]>>): Responder =>
  (request) => {
    const root = Object.keys(tables).find((name) => new RegExp(`\\b${name}\\s*\\(`).test(request.query));
    if (root === undefined) return undefined;
    const { where, order_by, limit, offset } = request.variables as {
      where?: unknown;
      order_by?: Array<Record<string, "asc" | "desc">>;
      limit?: number;
      offset?: number;
    };
    let rows = (tables[root] ?? []).filter((row) => matches(row, where));
    if (order_by !== undefined) {
      rows = [...rows].sort((a, b) => {
        for (const entry of order_by) {
          const [field, direction] = Object.entries(entry)[0] as [string, "asc" | "desc"];
          const c = compare(a[field], b[field]);
          if (c !== 0) return direction === "desc" ? -c : c;
        }
        return 0;
      });
    }
    const start = offset ?? 0;
    return { data: { [root]: rows.slice(start, limit === undefined ? undefined : start + limit) } };
  };
