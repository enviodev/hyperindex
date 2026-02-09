export interface Sql {
  (strings: TemplateStringsArray, ...values: unknown[]): Promise<any[]>;
  (obj: Record<string, unknown>): unknown;
  unsafe(query: string, params?: unknown[], options?: { prepare: boolean }): Promise<any[]>;
  begin<T>(callback: (sql: Sql) => Promise<T>): Promise<T>;
  end(): Promise<void>;
}

export default function createPool(config: Record<string, any>): Sql;
