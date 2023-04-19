CREATE TABLE IF NOT EXISTS "gravatar" (
	"id" text PRIMARY KEY NOT NULL,
	"owner" text,
	"displayName" text,
	"imageUrl" text,
	"updatesCount" text
);
