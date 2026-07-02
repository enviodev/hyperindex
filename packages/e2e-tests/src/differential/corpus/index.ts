import basic from "./01-basic.js";
import where from "./02-where.js";
import orderPagination from "./03-order-pagination.js";
import relationships from "./04-relationships.js";
import scalars from "./05-scalars.js";
import aggregates from "./06-aggregates.js";
import internalTables from "./07-internal-tables.js";
import errors from "./08-errors.js";
import introspection from "./09-introspection.js";
import limits from "./10-limits.js";
import whereMatrix from "./11-where-matrix.js";
import aggregateMatrix from "./12-aggregate-matrix.js";
import orderDistinctMatrix from "./13-order-distinct-matrix.js";
import variablesAndRequest from "./14-variables-and-request.js";
import scalarSerialization from "./15-scalar-serialization.js";
import relationshipMatrix from "./16-relationship-matrix.js";
import errorMatrix from "./17-error-matrix.js";
import type { CorpusCase } from "../corpus.js";

export const allCases: CorpusCase[] = [
  ...basic,
  ...where,
  ...orderPagination,
  ...relationships,
  ...scalars,
  ...aggregates,
  ...internalTables,
  ...errors,
  ...introspection,
  ...limits,
  ...whereMatrix,
  ...aggregateMatrix,
  ...orderDistinctMatrix,
  ...variablesAndRequest,
  ...scalarSerialization,
  ...relationshipMatrix,
  ...errorMatrix,
];
