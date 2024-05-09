const assert = require("assert");

function chainMetadataTests(db_chain_metadata, expected_chain_metadata) {
    assert(db_chain_metadata.chain_id == expected_chain_metadata.chain_id, `chain id should be ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.start_block == expected_chain_metadata.start_block, `start_block should be ${expected_chain_metadata.start_block} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.end_block == expected_chain_metadata.end_block, `end_block should be ${expected_chain_metadata.end_block} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.latest_processed_block == expected_chain_metadata.latest_processed_block, `latest_processed_block should be ${expected_chain_metadata.latest_processed_block} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.num_events_processed == expected_chain_metadata.num_events_processed, `num_events_processed should be ${expected_chain_metadata.num_events_processed} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.is_hyper_sync == expected_chain_metadata.is_hyper_sync, `is_hyper_sync should be ${expected_chain_metadata.is_hyper_sync} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.num_batches_fetched == expected_chain_metadata.num_batches_fetched, `num_batches_fetched should be ${expected_chain_metadata.num_batches_fetched} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.latest_fetched_block_number == expected_chain_metadata.latest_fetched_block_number, `num_batches_fetched should be ${expected_chain_metadata.latest_fetched_block_number} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.first_event_block_number == expected_chain_metadata.first_event_block_number, `num_batches_fetched should be ${expected_chain_metadata.first_event_block_number} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.block_height >= expected_chain_metadata.expected_block_height, `block_height should be greater than or equal to ${expected_chain_metadata.expected_block_height} for chain id ${expected_chain_metadata.chain_id}`);
    assert(db_chain_metadata.timestamp_caught_up_to_head_or_endblock != null, `timestamp_caught_up_to_head_or_endblock should not be null for chain id ${expected_chain_metadata.chain_id}`);
}

exports.chainMetadataTests = chainMetadataTests;
