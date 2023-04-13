CREATE TABLE IF NOT EXISTS "gravatar" (
	"id" serial PRIMARY KEY NOT NULL,
	"owner osf the gravatar" text,
	"display name of the gravatar" text,
	"image url of the gravatar" text,
	"updates count of the gravatar" integer
);
