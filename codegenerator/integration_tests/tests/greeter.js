const assert = require("assert");
let maxRetries = 120;

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
      greeting_by_pk("0xf28eA36e3E68Aff0e8c9bFF8037ba2150312ac48") {
        id
        numberOfGreetings
        greetings
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
      console.log("Could not request data from Hasura due to error: ", err);
      console.log("Hasura not yet started, retrying in 1s");
    }
    setTimeout(() => fetchQuery(query, callback), 1000);
  };

  // TODO: make this use promises rather than callbacks.
  fetchQuery(rawEventsQuery, (data) => {
    assert(
      data.raw_events_by_pk.event_type ===
      "PolygonGreeterContract_NewGreetingEvent",
      "event_type should be PolygonGreeterContract_NewGreetingEvent"
    );
    console.log("First test passed, running the second one.");

    // Run the second test
    fetchQuery(greetingEntityQuery, ({ greeting_by_pk: greeting }) => {
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

// After all async tasks are done
process.exit(0);
