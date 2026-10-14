// Prometheus text exposition (format 0.0.4), written by hand so the sidecar
// does not pull in a metrics library for a dozen series.

export type Labels = Readonly<Record<string, string>>;

export type Counter = { readonly inc: (labels?: Labels, by?: number) => void };
export type Histogram = { readonly observe: (labels: Labels, value: number) => void };

export const PROMETHEUS_CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8";

const DEFAULT_BUCKETS = [0.005, 0.01, 0.05, 0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300];

const escapeValue = (value: string) => value.replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/"/g, '\\"');

const labelText = (labels: Labels): string => {
  const entries = Object.entries(labels);
  if (entries.length === 0) return "";
  return `{${entries.map(([name, value]) => `${name}="${escapeValue(value)}"`).join(",")}}`;
};

const formatNumber = (value: number): string => {
  if (value === Number.POSITIVE_INFINITY) return "+Inf";
  if (value === Number.NEGATIVE_INFINITY) return "-Inf";
  return Number.isNaN(value) ? "NaN" : String(value);
};

const header = (name: string, help: string, type: string) => [`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`];

export type MetricsRegistry = {
  readonly counter: (name: string, help: string) => Counter;
  /** `collect` is read at scrape time, so gauges never go stale. */
  readonly gauge: (name: string, help: string, collect: () => ReadonlyArray<readonly [Labels, number]>) => void;
  readonly histogram: (name: string, help: string, buckets?: readonly number[]) => Histogram;
  readonly render: () => string;
};

export const createMetricsRegistry = (): MetricsRegistry => {
  const families: Array<() => string[]> = [];

  const counter = (name: string, help: string): Counter => {
    const values = new Map<string, number>();
    families.push(() => [
      ...header(name, help, "counter"),
      ...[...values].map(([labels, value]) => `${name}${labels} ${formatNumber(value)}`),
    ]);
    return {
      inc: (labels = {}, by = 1) => {
        const key = labelText(labels);
        values.set(key, (values.get(key) ?? 0) + by);
      },
    };
  };

  const gauge = (name: string, help: string, collect: () => ReadonlyArray<readonly [Labels, number]>) => {
    families.push(() => [
      ...header(name, help, "gauge"),
      ...collect().map(([labels, value]) => `${name}${labelText(labels)} ${formatNumber(value)}`),
    ]);
  };

  const histogram = (name: string, help: string, buckets: readonly number[] = DEFAULT_BUCKETS): Histogram => {
    const bounds = [...buckets].sort((a, b) => a - b);
    const series = new Map<string, { labels: Labels; counts: number[]; sum: number; count: number }>();
    families.push(() => {
      const lines = header(name, help, "histogram");
      for (const { labels, counts, sum, count } of series.values()) {
        bounds.forEach((bound, i) => {
          lines.push(`${name}_bucket${labelText({ ...labels, le: formatNumber(bound) })} ${counts[i] ?? 0}`);
        });
        lines.push(`${name}_bucket${labelText({ ...labels, le: "+Inf" })} ${count}`);
        lines.push(`${name}_sum${labelText(labels)} ${formatNumber(sum)}`);
        lines.push(`${name}_count${labelText(labels)} ${count}`);
      }
      return lines;
    });
    return {
      observe: (labels, value) => {
        const key = labelText(labels);
        let entry = series.get(key);
        if (entry === undefined) {
          entry = { labels, counts: bounds.map(() => 0), sum: 0, count: 0 };
          series.set(key, entry);
        }
        // Buckets are cumulative: an observation counts in every bucket at or above it.
        bounds.forEach((bound, i) => {
          if (value <= bound && entry !== undefined) entry.counts[i] = (entry.counts[i] ?? 0) + 1;
        });
        entry.sum += value;
        entry.count++;
      },
    };
  };

  return {
    counter,
    gauge,
    histogram,
    render: () => `${families.flatMap((family) => family()).join("\n")}\n`,
  };
};
