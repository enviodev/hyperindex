// Test that wildcard events with filters work. No address is applied to the wildcard event.
// and only DAI pools should be indexed.
const assert = require("assert");
const {
  fetchQueryWithTestCallback,
} = require("./graphqlFetchWithTestCallback");
const { chainMetadataTests } = require("./databaseTestHelpers");

const DAI_ADDRESS = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
const maxRetryMessage =
  "Max retries reached - if you have changed the shape of the chain_metadata table update this test and the UI before releasing.";

const pollGraphQL = async () => {
  const customSchema = process.env.ENVIO_PG_PUBLIC_SCHEMA;
  const poolCreatedQuery = `query {
    ${customSchema ? `${customSchema}_PoolCreated` : `PoolCreated`} {
      token0
      token1
    }
  }
  `;

  console.log("Starting endblock restart tests for dynamic contracts");
  // TODO: make this use promises rather than callbacks.
  fetchQueryWithTestCallback(
    poolCreatedQuery,
    maxRetryMessage,
    ({ PoolCreated }) => {
      try {
        assert(
          PoolCreated.length > 1,
          "Should return at least 1 PoolCreated event"
        );

        PoolCreated.forEach((event) => {
          assert(
            event.token0 === DAI_ADDRESS || event.token1 === DAI_ADDRESS,
            "Should have DAI address in either token0 or token1"
          );
        });
      } catch (err) {
        //gotta love javascript
        err.shouldExitOnFailure = true;
        throw err;
      }
      console.log("Finished running dynamic contract chain_metadata tests");
    }
  );
};

pollGraphQL();
