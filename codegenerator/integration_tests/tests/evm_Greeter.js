const assert = require("assert");
const {
  fetchQueryWithTestCallback,
} = require("./graphqlFetchWithTestCallback");

const maxRetryFailureMessage =
  "Max retries reached - either increase the timeout (maxRetries) or check for other bugs.";

const pollGraphQL = async () => {
  const userEntityQuery = `
    {
      User_by_pk(id: "0xf28eA36e3E68Aff0e8c9bFF8037ba2150312ac48") {
        id
        greetings
        numberOfGreetings
      }
    }
  `;

  console.log("[js context] Starting running test Greeter - user entity check");
  fetchQueryWithTestCallback(
    userEntityQuery,
    maxRetryFailureMessage,
    ({ User_by_pk: user }) => {
      let shouldExitOnFailure = false;
      try {
        assert(!!user, "greeting should not be null or undefined");
        assert(user.greetings.includes("gm Linea"), true);
        assert(user.greetings.includes("gm"), true);
        assert(user.greetings.includes("gn"), true);
        assert(user.greetings.includes("gm paris"), true);
        assert(user.numberOfGreetings >= 3, "numberOfGreetings should be >= 3");
        console.log("Second test passed.");
      } catch (err) {
        //gotta love javascript
        err.shouldExitOnFailure = shouldExitOnFailure;
        throw err;
      }
    }
  );
};

pollGraphQL();
