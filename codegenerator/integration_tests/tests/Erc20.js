const assert = require("assert");
const { exit } = require("process");
let maxRetries = 120;

let shouldExitOnFailure = false; // This flag is set to true once all setup has completed and test is being performed.

const pollGraphQL = async () => {
  const rawEventsQuery = `
    query {
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
      Account_by_pk(id: "0x894C63809B72207da77e4fa89E2d5cC003171B6a") {
        approvals(order_by: {event_id: asc}) {
          amount
          owner
          spender
        }
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
      if (!shouldExitOnFailure) {
        console.log("[will retry] Could not request data from Hasura due to error: ", err);
        console.log("Hasura not yet started, retrying in 1s");
      } else {
        console.error(err);
        exit(1);
      }
    }
    setTimeout(() => { if (!shouldExitOnFailure) fetchQuery(query, callback) }, 1000);
  };

  // TODO: make this use promises rather than callbacks.
  fetchQuery(rawEventsQuery, (data) => {
    assert(
      data.raw_events_by_pk.event_type === "ERC20Contract_TransferEvent",
      "event_type should be TransferEvent"
    );
    console.log("First test passed, running the second one.");

    // Run the second test
    fetchQuery(accountEntityQuery, ({ Account_by_pk: account }) => {
      assert(!!account, "account should not be null or undefined");
      shouldExitOnFailure = true;
      assert(account.balance == 70, "balance should be == 70"); // NOTE the balance shouldn't change since we own this erc20 token.
      assert(account.approvals.length > 0, "There should be at least one approval");
      assert(account.approvals[0].amount == 50, "The first approval amount should be 50");
      assert(account.approvals[0].owner == account.id, "The first approval owner should be the account id");
      assert(account.approvals[0].spender == "0x894C63809B72207da77e4fa89E2d5cC003171B6a" /* The spender is himself, bad script... */, "The first approval spender should be the account id");
      console.log("Second test passed.");
    });
  });
};

pollGraphQL();

