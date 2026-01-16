/**
 * Indexer exit behavior tests
 */

import { GraphQLTestCase } from "../types.js";

interface ChainMetadata {
  chain_id: number;
  start_block: number;
  end_block: number | null;
  block_height: number;
  first_event_block_number: number | null;
  latest_processed_block: number | null;
  num_events_processed: number | null;
  is_hyper_sync: boolean;
  num_batches_fetched: number;
  latest_fetched_block_number: number;
  timestamp_caught_up_to_head_or_endblock: string | null;
}

interface EndblockQueryResult {
  chain_metadata: ChainMetadata[];
}

/**
 * Validates chain metadata fields are properly set
 */
function validateChainMetadata(metadata: ChainMetadata): boolean {
  // Required fields should be set
  if (metadata.chain_id === undefined) return false;
  if (metadata.start_block === undefined) return false;
  if (metadata.block_height === undefined) return false;
  if (metadata.is_hyper_sync === undefined) return false;

  // Should have processed some events
  if (
    metadata.num_events_processed === null ||
    metadata.num_events_processed < 0
  )
    return false;

  // Should have fetched some blocks
  if (metadata.num_batches_fetched < 0) return false;

  return true;
}

export const endblockSuccessTests: GraphQLTestCase<EndblockQueryResult>[] = [
  {
    description: "Chain metadata is properly populated after sync",
    query: `
      {
        chain_metadata {
          chain_id
          start_block
          end_block
          block_height
          first_event_block_number
          latest_processed_block
          num_events_processed
          is_hyper_sync
          num_batches_fetched
          latest_fetched_block_number
          timestamp_caught_up_to_head_or_endblock
        }
      }
    `,
    validate: (data) => {
      if (!data.chain_metadata || data.chain_metadata.length === 0) {
        return false;
      }

      return data.chain_metadata.every(validateChainMetadata);
    },
  },
];

interface DynamicContract {
  id: string;
  contract_address: string;
  contract_name: string;
  chain_id: number;
}

interface DynamicContractsQueryResult {
  dynamic_contract_registry: DynamicContract[];
}

export const dynamicContractTests: GraphQLTestCase<DynamicContractsQueryResult>[] =
  [
    {
      description: "Dynamic contracts are registered",
      query: `
      {
        dynamic_contract_registry {
          id
          contract_address
          contract_name
          chain_id
        }
      }
    `,
      validate: (data) => {
        // Should have at least one dynamically registered contract
        return (
          data.dynamic_contract_registry &&
          data.dynamic_contract_registry.length > 0
        );
      },
    },
  ];

interface PoolCreated {
  id: string;
  token0: string;
  token1: string;
}

interface WildcardUniFactoryQueryResult {
  PoolCreated: PoolCreated[];
}

export const wildcardUniFactoryTests: GraphQLTestCase<WildcardUniFactoryQueryResult>[] =
  [
    {
      description: "Pool created events are indexed",
      query: `
      {
        PoolCreated(limit: 10) {
          id
          token0
          token1
        }
      }
    `,
      validate: (data) => {
        return data.PoolCreated && data.PoolCreated.length > 0;
      },
    },
  ];
