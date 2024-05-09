// This test is two fold, firstly checking that the indexer is in the correct state after exiting with success
// and secondly that the chain_metadata table is in the correct shape. The chain_metadata table is used by the UI
// and so any changes should be tested for
const assert = require("assert");
const { fetchQueryWithTestCallback } = require("./graphqlFetchWithTestCallback");

const maxRetryMessage = "Max retries reached - if you have changed the shape of the chain_metadata table update this test and the UI before releasing."

let chainMetadataTests = (db_chain_metadata, expected_chain_metadata) => {
    assert(db_chain_metadata.chain_id == expected_chain_metadata.chain_id, `chain id should be ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.start_block == expected_chain_metadata.start_block, `start_block should be ${expected_chain_metadata.start_block} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.end_block == expected_chain_metadata.end_block, `end_block should be ${expected_chain_metadata.end_block} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.latest_processed_block == expected_chain_metadata.latest_processed_block, `latest_processed_block should be ${expected_chain_metadata.latest_processed_block} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.num_events_processed == expected_chain_metadata.num_events_processed, `num_events_processed should be ${expected_chain_metadata.num_events_processed} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.is_hyper_sync == expected_chain_metadata.is_hyper_sync, `is_hyper_sync should be ${expected_chain_metadata.is_hyper_sync} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.num_batches_fetched == expected_chain_metadata.num_batches_fetched, `num_batches_fetched should be ${expected_chain_metadata.num_batches_fetched} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.latest_fetched_block_number == expected_chain_metadata.latest_fetched_block_number, `num_batches_fetched should be ${expected_chain_metadata.latest_fetched_block_number} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.first_event_block_number == expected_chain_metadata.first_event_block_number, `num_batches_fetched should be ${expected_chain_metadata.first_event_block_number} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.block_height >= db_chain_metadata.end_block, `block_height should be greater than or equal to endblock for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.timestamp_caught_up_to_head_or_endblock != null, `timestamp_caught_up_to_head_or_endblock should not be null for chain id ${expected_chain_metadata.chain_id}`);
}
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
        let shouldExitOnFailure = false;
        assert(chain_metadata.length == 5, "Should return 5 chain metadata objects");
        let ethereum_chain_metadata = chain_metadata[0];
        let optimism_chain_metadata = chain_metadata[1];
        let polygon_chain_metadata = chain_metadata[2];
        let base_chain_metadata = chain_metadata[3];
        let arbitrum_chain_metadata = chain_metadata[4];
        //expected chain metadata
        //block_height and timestamp_caught_up_to_head_or_endblock are variable so will check if they exist
        let expected_ethereum_chain_metadata = {
            chain_id: 1,
            start_block: 0,
            end_block: 2000000,
            latest_processed_block: 2000000,
            num_events_processed: 0,
            is_hyper_sync: true,
            num_batches_fetched: 1,
            latest_fetched_block_number: 2000000,
            first_event_block_number: null
        }
        shouldExitOnFailure = true;
        let expected_optimism_chain_metadata = {
            chain_id: 10,
            start_block: 0,
            end_block: 50000,
            latest_processed_block: 50000,
            num_events_processed: 200,
            is_hyper_sync: true,
            num_batches_fetched: 1,
            latest_fetched_block_number: 50000,
            first_event_block_number: 3068
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
            first_event_block_number: null
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
            first_event_block_number: null
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
        }
        chainMetadataTests(ethereum_chain_metadata, expected_ethereum_chain_metadata)
        chainMetadataTests(optimism_chain_metadata, expected_optimism_chain_metadata)
        chainMetadataTests(polygon_chain_metadata, expected_polygon_chain_metadata)
        chainMetadataTests(base_chain_metadata, expected_base_chain_metadata)
        chainMetadataTests(arbitrum_chain_metadata, expected_arbitrum_chain_metadata)
        console.log("Finished running tests");
        return shouldExitOnFailure;
    });
};

pollGraphQL();

