const assert = require("assert");
const { exit } = require("process");
let maxRetries = 200;

let shouldExitOnFailure = false; // This flag is set to true once all setup has completed and test is being performed.

const pollGraphQL = async () => {
  const rawEventsQuery = `
    query {
      raw_events_by_pk(chain_id: 1, event_id: "712791818308") {
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
      Account_by_pk(id: "0x26921A182Cf9D6F33730D7F37E1a86fd430863Af") {
        approvals(order_by: {event_id: asc}, limit: 2) {
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
        console.log("Hasura not yet started, retrying in 2s");
      } else {
        console.error(err);
        process.exit(1);
      }
    }
    setTimeout(() => { if (!shouldExitOnFailure) fetchQuery(query, callback) }, 2000);
  };

  console.log("Starting running test")

  // TODO: make this use promises rather than callbacks.
  fetchQuery(rawEventsQuery, (data) => {
    assert(
      data.raw_events_by_pk.event_type === "ERC20Contract_ApprovalEvent",
      "event_type should be an ApprovalEvent"
    );
    console.log("First test passed, running the second one.");


    // Run the second test
    fetchQuery(accountEntityQuery, ({ Account_by_pk: account }) => {
      assert(!!account, "account should not be null or undefined");
      shouldExitOnFailure = true;
      assert(account.balance > 311465476000000000000, "balance should be == 70"); // NOTE the balance shouldn't change since we own this erc20 token.
      assert(account.approvals.length > 0, "There should be at least one approval");
      assert(account.approvals[0].amount == 79228162514264337593543950335n, "The first approval amount should be 50");
      assert(account.approvals[0].owner == account.id, "The first approval owner should be the account id");
      assert(account.approvals[0].spender == "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", "The first approval spender should be correct (from uniswap)");
      console.log("Second test passed.");
    });
  });
};

pollGraphQL();

