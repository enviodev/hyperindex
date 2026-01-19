// This test is two fold, firstly checking that the indexer is in the correct state after exiting with success
// and secondly that the chain_metadata table is in the correct shape. The chain_metadata table is used by the UI
// and so any changes should be tested for
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

    console.log("Starting endblock tests")
    // TODO: make this use promises rather than callbacks.
    fetchQueryWithTestCallback(chainMetaDataQuery, maxRetryMessage, ({ chain_metadata }) => {
        try {
            assert(chain_metadata.length == 5, "Should return 5 chain metadata objects");
            let ethereum_chain_metadata = chain_metadata[0];
            let optimism_chain_metadata = chain_metadata[1];
            let polygon_chain_metadata = chain_metadata[2];
            let base_chain_metadata = chain_metadata[3];
            let arbitrum_chain_metadata = chain_metadata[4];
            //expected chain metadata
            //timestamp_caught_up_to_head_or_endblock is variable so will check if they exist
            let expected_ethereum_chain_metadata = {
                chain_id: 1,
                start_block: 0,
                end_block: 2000000,
                latest_processed_block: 2000000,
                num_events_processed: 0,
                is_hyper_sync: true,
                num_batches_fetched: 1,
                latest_fetched_block_number: 2000000,
                first_event_block_number: null,
                expected_block_height: 2000000,
            }
            let expected_optimism_chain_metadata = {
                chain_id: 10,
                start_block: 0,
                end_block: 50000,
                latest_processed_block: 50000,
                num_events_processed: 200,
                is_hyper_sync: true,
                num_batches_fetched: 1,
                latest_fetched_block_number: 50000,
                first_event_block_number: 3068,
                expected_block_height: 50000,
            }
            let expected_polygon_chain_metadata = {
                chain_id: 137,
                start_block: 0,
                end_block: 2000000,
                latest_processed_block: 2000000,
                num_events_processed: 0,
                is_hyper_sync: true,
                num_batches_fetched: 1,
                latest_fetched_block_number: 2000000,
                first_event_block_number: null,
                expected_block_height: 2000000,
            }
            let expected_base_chain_metadata = {
                chain_id: 8453,
                start_block: 0,
                end_block: 2000000,
                latest_processed_block: 2000000,
                num_events_processed: 0,
                is_hyper_sync: true,
                num_batches_fetched: 1,
                latest_fetched_block_number: 2000000,
                first_event_block_number: null,
                expected_block_height: 2000000,
            }
            let expected_arbitrum_chain_metadata = {
                chain_id: 42161,
                start_block: 0,
                end_block: 500000,
                latest_processed_block: 500000,
                num_events_processed: 10505,
                is_hyper_sync: true,
                num_batches_fetched: 1,
                latest_fetched_block_number: 500000,
                first_event_block_number: 100904,
                expected_block_height: 500000,
            }
            chainMetadataTests(ethereum_chain_metadata, expected_ethereum_chain_metadata)
            chainMetadataTests(optimism_chain_metadata, expected_optimism_chain_metadata)
            chainMetadataTests(polygon_chain_metadata, expected_polygon_chain_metadata)
            chainMetadataTests(base_chain_metadata, expected_base_chain_metadata)
            chainMetadataTests(arbitrum_chain_metadata, expected_arbitrum_chain_metadata)
        }
        catch (err) {
            //gotta love javascript
            err.shouldExitOnFailure = true
            throw err;
        }
        console.log("Finished running tests");
    });
};

pollGraphQL();

