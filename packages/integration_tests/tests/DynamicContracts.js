// Test that a dynamic contract indexer that has restarted still maintains the correct chain metadata
const assert = require("assert");
const { fetchQueryWithTestCallback } = require("./graphqlFetchWithTestCallback");
const { chainMetadataTests } = require("./databaseTestHelpers")

const maxRetryMessage = "Max retries reached - if you have changed the shape of the chain_metadata table update this test and the UI before releasing."

const pollGraphQL = async () => {
    const chainMetaDataQuery = `
    query {
        chain_metadata(order_by: {chain_id: asc}) {
        chain_id
        block_height
        start_block
        end_block
        latest_processed_block
        num_events_processed
        is_hyper_sync
        num_batches_fetched
        latest_fetched_block_number
        first_event_block_number
        timestamp_caught_up_to_head_or_endblock
        }
    }
  `;

    console.log("Starting endblock restart tests for dynamic contracts")
    // TODO: make this use promises rather than callbacks.
    fetchQueryWithTestCallback(chainMetaDataQuery, maxRetryMessage, ({ chain_metadata }) => {
        try {
            assert(chain_metadata.length == 1, "Should return 1 chain metadata object");
            let optimism_chain_metadata = chain_metadata[0];
            //expected chain metadata
            //timestamp_caught_up_to_head_or_endblock is variable so will check if they exist
            let expected_optimism_chain_metadata = {
                chain_id: 10,
                start_block: 4556306,
                end_block: 6942099,
                latest_processed_block: 6942099,
                num_events_processed: 41183,
                is_hyper_sync: true,
                num_batches_fetched: 0, //this is reset after restart
                latest_fetched_block_number: 6942099,
                first_event_block_number: 4556306,
                expected_block_height: 0, // 0 on restarts
            }
            chainMetadataTests(optimism_chain_metadata, expected_optimism_chain_metadata)
        }
        catch (err) {
            //gotta love javascript
            err.shouldExitOnFailure = true
            throw err;
        }
        console.log("Finished running dynamic contract chain_metadata tests");
    });
};

pollGraphQL();

