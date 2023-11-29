const assert = require("assert");
let maxRetries = 200;

let shouldExitOnFailure = false; // This flag is set to true once all setup has completed and test is being performed.

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

  const greetingEntityQuery = `
    {
      Greeting_by_pk(id: "0xf28eA36e3E68Aff0e8c9bFF8037ba2150312ac48") {
        id
        greetings
        numberOfGreetings
      }
    }
  `;

  let retries = 0;
  // TODO: make this configurable
  const endpoint = "http://localhost:8080/v1/graphql";

  const fetchQuery = async (query, callback) => {
    if (retries >= maxRetries) {
      throw new Error(
        "Max retries reached - either increase the timeout (maxRetries) or check for other bugs."
      );
    }
    retries++;

    try {
      const response = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query }),
      });

      const { data, errors } = await response.json();

      if (data) {
        console.log("returned data", data);
        callback(data);
        return;
      } else {
        console.log("data not yet available, retrying in 1s");
      }

      if (errors) {
        console.error(errors);
      }
    } catch (err) {
      if (!shouldExitOnFailure) {
        console.log("[will retry] Could not request data from Hasura due to error: ", err);
        console.log("Hasura not yet started, retrying in 1s");
      } else {
        console.error(err);
        process.exit(1);
      }
    }
    setTimeout(() => { if (!shouldExitOnFailure) fetchQuery(query, callback) }, 1000);
  };

  console.log("[js context] Starting running test Greeter")

  // TODO: make this use promises rather than callbacks.
  fetchQuery(rawEventsQuery, (data) => {
    assert(
      data.raw_events_by_pk.event_type ===
      "Greeter_NewGreeting",
      "event_type should be Greeter_NewGreeting"
    );
    console.log("First test passed, running the second one.");

    // Run the second test
    fetchQuery(greetingEntityQuery, ({ Greeting_by_pk: greeting }) => {
      assert(!!greeting, "greeting should not be null or undefined")
      assert(
        greeting.greetings.slice(0, 3).toString() === "gm,gn,gm paris",
        "First 3 greetings should be 'gm,gn,gm paris'"
      );
      assert(
        greeting.numberOfGreetings >= 3,
        "numberOfGreetings should be >= 3"
      );
      console.log("Second test passed.");
    });
  });
};

pollGraphQL();

