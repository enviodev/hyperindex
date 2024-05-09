const assert = require("assert");
const { fetchQueryWithTestCallback } = require("./graphqlFetchWithTestCallback");

const maxRetryFailureMessage = "Max retries reached - either increase the timeout (maxRetries) or check for other bugs."

const pollGraphQL = async () => {
  const rawEventsQuery = `
    query {
      raw_events_by_pk(event_id: "3071145413242", chain_id: 137) {
        event_type
        log_index
        src_address
        transaction_hash
        transaction_index
        block_number
      }
    }
  `;

  const userEntityQuery = `
    {
      User_by_pk(id: "0xf28eA36e3E68Aff0e8c9bFF8037ba2150312ac48") {
        id
        greetings
        numberOfGreetings
      }
    }
  `;

  console.log("[js context] Starting running test Greeter");
  // TODO: make this use promises rather than callbacks.
  fetchQueryWithTestCallback(rawEventsQuery, maxRetryFailureMessage, (data) => {
    let shouldExitOnFailure = false;
    assert(
      data.raw_events_by_pk.event_type === "Greeter_NewGreeting",
      "event_type should be Greeter_NewGreeting"
    );
    console.log("First test passed, running the second one.");

    // Run the second test
    fetchQuery(userEntityQuery, maxRetryFailureMessage, ({ User_by_pk: user }) => {
      assert(!!user, "greeting should not be null or undefined");
      assert(
        user.greetings.slice(0, 3).toString() === "gm,gn,gm paris",
        "First 3 greetings should be 'gm,gn,gm paris'"
      );
      assert(user.numberOfGreetings >= 3, "numberOfGreetings should be >= 3");
      console.log("Second test passed.");
      return shouldExitOnFailure;
    });
    return shouldExitOnFailure;
  });
};

pollGraphQL();
