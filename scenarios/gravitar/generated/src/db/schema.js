const {
  pgTable,
  serial,
  text,
  varchar,
  integer,
} = require("drizzle-orm/pg-core");

const gravatar = pgTable("gravatar", {
  id: serial("id").primaryKey(),
  owner: text("owner of the gravatar"),
  displayName: text("display name of the gravatar"),
  imageUrl: text("image url of the gravatar"),
  updatesCount: integer("updates count of the gravatar"),
});

module.exports.gravatar = gravatar;
