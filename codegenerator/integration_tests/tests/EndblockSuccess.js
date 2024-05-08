const assert = require("assert");
const { exit } = require("process");
let maxRetries = 5;

let shouldExitOnFailure = false; // This flag is set to true once all setup has completed and test is being performed.
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


    let retries = 0;
    // TODO: make this configurable
    const endpoint = "http://localhost:8080/v1/graphql";

    const fetchQuery = async (query, callback) => {
        if (retries >= maxRetries) {
            throw new Error(
                "Max retries reached - if you have changed the shape of the chain_metadata table update this test and the UI before releasing."
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
    fetchQuery(chainMetaDataQuery, ({ chain_metadata }) => {
        assert(chain_metadata.length == 5, "Should return 5 chain metadata objects");
        let ethereum_chain_metadata = chain_metadata[0];
        console.log("ethereum_chain_metadata", ethereum_chain_metadata)
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

    });
};

pollGraphQL();

