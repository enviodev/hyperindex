ALTER TABLE gravatar RENAME COLUMN "owner osf the gravatar" TO "owner of the gravatar";
ALTER TABLE gravatar ALTER COLUMN "id" SET DATA TYPE text;