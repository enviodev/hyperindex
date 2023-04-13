let { db } = require("./db.js");
let { gravatar } = require("./schema.js");

let batchSetGravatars = async (gravatarsArray) => {
  let res = await db.insert(gravatar).values(gravatarsArray);

  let obj = Object.entries(res);
  console.log(obj);
};

let test = batchSetGravatars(
  // {
  //   id: "hi",
  //   owner: "hello",
  //   displayName: "hi mom",
  //   updatesCount: 201,
  //   imageUrl: "hi.com",
  // },
  // {
  //   id: "hi2",
  //   owner: "hello",
  //   displayName: "hi mom",
  //   updatesCount: 201,
  //   imageUrl: "hi.com",
  // },
  [
    {
      id: "hi4",
      owner: "hello2",
      displayName: "hi mom",
      updatesCount: 201,
      imageUrl: "hi.com",
    },
  ]
);
