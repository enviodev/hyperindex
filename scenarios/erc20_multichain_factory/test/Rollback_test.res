//Test 1
//Chain 1 & chain 2 index events in batches of 2
//Chain 1 rollsback to a block in between two endOfRange blocks on the other chain
//Chain 1 should roll back to its known block and index, and start indexing from that block
//Chain 2 should start indexing from an earlier block (known) but discard blocks until it finds the
//actual block where the rollback went to

