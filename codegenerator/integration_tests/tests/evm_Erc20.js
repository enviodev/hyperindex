const assert = require("assert");
const { exit } = require("process");
const {
  fetchQueryWithTestCallback,
} = require("./graphqlFetchWithTestCallback");

const maxRetryFailureMessage =
  "Max retries reached - either increase the timeout (maxRetries) or check for other bugs.";

const pollGraphQL = async () => {
  const rawEventsQuery = `
    query {
      raw_events_by_pk(chain_id: 1, event_id: "712791818308") {
        event_type
        log_index
        src_address
        block_number
      }
    }
  `;

  const accountEntityQuery = `
    {
      Account_by_pk(id: "0x26921A182Cf9D6F33730D7F37E1a86fd430863Af") {
        approvals(order_by: {db_write_timestamp: asc}, limit: 2) {
          amount
          owner_id
          spender_id
        }
        balance
        id
      }
    }
  `;

  console.log("Starting erc20 tests - raw events approval event test");
  // TODO: make this use promises rather than callbacks.
  fetchQueryWithTestCallback(rawEventsQuery, maxRetryFailureMessage, (data) => {
    let shouldExitOnFailure = false;
    try {
      assert(
        data.raw_events_by_pk.event_type === "ERC20_Approval",
        "event_type should be an Approval",
      );
      console.log("First erc20 test passed, running account entity test.");

      // Run the second test
      fetchQueryWithTestCallback(
        accountEntityQuery,
        maxRetryFailureMessage,
        ({ Account_by_pk: account }) => {
          try {
            assert(!!account, "account should not be null or undefined");
            shouldExitOnFailure = true;

            assert(
              account.balance > 311465476000000000000,
              "balance should be == 70",
            ); // NOTE the balance shouldn't change since we own this erc20 token.
            assert(
              account.approvals.length > 0,
              "There should be at least one approval",
            );
            assert(
              account.approvals[0].amount == 79228162514264337593543950335n,
              "The first approval amount should be 50",
            );
            assert(
              account.approvals[0].owner_id == account.id,
              "The first approval owner should be the account id",
            );
            assert(
              account.approvals[0].spender_id ==
              "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
              "The first approval spender should be correct (from uniswap)",
            );
          } catch (err) {
            //gotta love javascript
            err.shouldExitOnFailure = shouldExitOnFailure;
            throw err;
          }
          console.log("Second test passed.");
        },
      );
    } catch (err) {
      //gotta love javascript
      err.shouldExitOnFailure = shouldExitOnFailure;
      throw err;
    }
  });
};

pollGraphQL();
