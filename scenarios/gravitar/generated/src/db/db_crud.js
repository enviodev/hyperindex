let { db } = require("./db_crud.js");

let batchUpsertGravatars = async (gravatarsArray) => {
  await db
    .insert(users)
    .values(gravatarsArray)
    .onConflictDoUpdate(gravatarsArray.map((gravatar) => { target: gravatar.id, set: { owner: gravitar.owner, displayName: gravitar.displayName, imageUrl: gravitar.imageUrl, updatesCount: gravitar.updatesCount } });
};

