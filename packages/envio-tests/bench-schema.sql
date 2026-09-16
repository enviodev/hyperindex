DROP SCHEMA IF EXISTS "bench" CASCADE;
CREATE SCHEMA "bench";
-- No date column, so the batch goes in through one unnest per column.
CREATE TABLE "bench"."unnested" (
  "id" TEXT NOT NULL,
  "sender" BYTEA NOT NULL,
  "receiver" BYTEA NOT NULL,
  "amount" NUMERIC NOT NULL,
  "block_number" INTEGER NOT NULL,
  "is_burn" BOOLEAN NOT NULL,
  PRIMARY KEY ("id")
);
-- The same, plus the date that puts it on the statement binding every cell.
CREATE TABLE "bench"."valued" (
  "id" TEXT NOT NULL,
  "sender" BYTEA NOT NULL,
  "receiver" BYTEA NOT NULL,
  "amount" NUMERIC NOT NULL,
  "block_number" INTEGER NOT NULL,
  "is_burn" BOOLEAN NOT NULL,
  "at" TIMESTAMP WITH TIME ZONE NOT NULL,
  PRIMARY KEY ("id")
);
