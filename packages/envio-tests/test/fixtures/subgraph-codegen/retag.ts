/** Same rewrite the Node load hook applies to `changetype<Foo>(x)`. */
export const retagChangetypeCalls = (source: string): string =>
  source.replace(
    /changetype\s*<\s*([A-Za-z_][A-Za-z0-9_]*)\s*>\s*\(/g,
    "__envio_retag($1, ",
  );
