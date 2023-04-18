CREATE TABLE IF NOT EXISTS "user" (
	"idExample" text PRIMARY KEY NOT NULL,
	"id" text PRIMARY KEY NOT NULL,
	"address" text,
	"gravatar" text,
	"balance" text
);

CREATE TABLE IF NOT EXISTS "balance" (
	"idExample" text PRIMARY KEY NOT NULL,
	"id" text PRIMARY KEY NOT NULL,
	"balance" text,
	"user" text,
	"gravatar" text
);

CREATE TABLE IF NOT EXISTS "profile" (
	"idExample" text PRIMARY KEY NOT NULL,
	"id" text PRIMARY KEY NOT NULL,
	"displayName" text,
	"gravatar" text,
	"user" text
);

ALTER TABLE "gravatar" ADD COLUMN "idExample" text NOT NULL;
ALTER TABLE "gravatar" ADD COLUMN "balance" text;