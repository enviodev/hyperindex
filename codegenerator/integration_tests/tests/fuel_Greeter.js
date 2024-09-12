const assert = require("assert");
const {
  fetchQueryWithTestCallback,
} = require("./graphqlFetchWithTestCallback");

const maxRetryFailureMessage =
  "Max retries reached - either increase the timeout (maxRetries) or check for other bugs.";

const pollGraphQL = async () => {
  const userEntityQuery = `
    {
      User_by_pk(id: "0x2072fe0e4c1cf1fe7ba3c4569992908fe4d7aecc9655c9d0c4da9285ade32c5f") {
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
        assert(
          user.greetings.slice(0, 3).toString() ===
            "Hi envio,NotHello,Hi Again",
          "First 3 greetings should be 'Hi envio,NotHello,Hi Again'"
        );
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
