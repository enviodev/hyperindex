const assert = require("assert");
const {
  fetchQueryWithTestCallback,
} = require("./graphqlFetchWithTestCallback");

const maxRetryFailureMessage =
  "Max retries reached - either increase the timeout (maxRetries) or check for other bugs.";

const pollGraphQL = async () => {
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

  console.log("Starting erc20 tests - account entity test");
  // TODO: make this use promises rather than callbacks.
  fetchQueryWithTestCallback(
    accountEntityQuery,
    maxRetryFailureMessage,
    ({ Account_by_pk: account }) => {
      let shouldExitOnFailure = false;
      try {
        assert(!!account, "account should not be null or undefined");
        shouldExitOnFailure = true;

        assert(
          account.balance > 311465476000000000000,
          "balance should be == 70"
        ); // NOTE the balance shouldn't change since we own this erc20 token.
        assert(
          account.approvals.length > 0,
          "There should be at least one approval"
        );
        assert(
          account.approvals[0].amount == 79228162514264337593543950335n,
          "The first approval amount should be 50"
        );
        assert(
          account.approvals[0].owner_id == account.id,
          "The first approval owner should be the account id"
        );
        assert(
          account.approvals[0].spender_id ==
            "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
          "The first approval spender should be correct (from uniswap)"
        );
      } catch (err) {
        //gotta love javascript
        err.shouldExitOnFailure = shouldExitOnFailure;
        throw err;
      }
      console.log("Second test passed.");
    }
  );
};

pollGraphQL();
