const assert = require("assert");
const { exit } = require("process");
let maxRetries = 200;

let shouldExitOnFailure = false; // This flag is set to true once all setup has completed and test is being performed.
let maxRetries = 120;

const pollGraphQL = async () => {
  const rawEventsQuery = `
    query {
      raw_events_by_pk(chain_id: 1, event_id: "712791818308") {
      raw_events_by_pk(chain_id: 5, event_id: "622184760610") {
        event_type
        log_index
        src_address
        transaction_hash
        transaction_index
        block_number
      }
    }
  `;

  const accountEntityQuery = `
    {
      account_by_pk(id: "0x0000000000000000000000000000000000000000") {
        approval
        balance
        id
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
      data.raw_events_by_pk.event_type === "ERC20Contract_TransferEvent",
      "event_type should be TransferEvent"
    );
    console.log("First test passed, running the second one.");

    // Run the second test
    fetchQuery(accountEntityQuery, ({ account_by_pk: account }) => {
      assert(!!account, "account should not be null or undefined");
      assert(account.balance <= -103, "balance should be <= -103");
      assert(account.approval == 0, "approval should be = 0");
      console.log("Second test passed.");
    });
  });
};

pollGraphQL();

// After all async tasks are done
process.exit(0);
