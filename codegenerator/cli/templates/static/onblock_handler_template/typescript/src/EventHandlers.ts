/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import {
    ERC20,
    TotalSupply,
    TotalSupplySnapshot,
    onBlock
} from "generated";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

onBlock(
    {
        name: "TotalSupplySnapshot",
        chain: 1,
        interval: 1000,
    }
    ,
    async ({ block, context }) => {
        const latestSupply = await context.TotalSupply.get("latest");
        if (!latestSupply) {
            return;
        }

        const supply = latestSupply.currentSupply;
        const blockNumber = latestSupply.blockNumber;
        const timestamp = latestSupply.timestamp;

        const totalSupplySnapshot: TotalSupplySnapshot = {
            id: `${block.chainId}_${block.number}`,
            supply: supply,
            blockNumber: blockNumber,
            timestamp: timestamp,
        };

        context.TotalSupplySnapshot.set(totalSupplySnapshot);
    });

ERC20.Transfer.handler(async ({ event, context }) => {
    const { from, to, amount } = event.params;

    // Only track transfers to/from zero address (minting/burning)
    if (from.toLowerCase() !== ZERO_ADDRESS && to.toLowerCase() !== ZERO_ADDRESS) {
        return;
    }

    const latestSupply = await context.TotalSupply.getOrCreate({
        id: "latest",
        currentSupply: BigInt(0),
        blockNumber: BigInt(event.block.number),
        timestamp: BigInt(event.block.timestamp),
    });

    // Calculate new total supply
    let newSupply: bigint;

    if (from.toLowerCase() === ZERO_ADDRESS) {
        // Minting: transfer from zero address increases supply
        newSupply = latestSupply.currentSupply + amount;
    } else {
        // Burning: transfer to zero address decreases supply
        newSupply = latestSupply.currentSupply - amount;
    }

    // Update the "latest" entry for future calculations
    const latestEntity: TotalSupply = {
        id: "latest",
        currentSupply: newSupply,
        blockNumber: BigInt(event.block.number),
        timestamp: BigInt(event.block.timestamp),
    };

    context.TotalSupply.set(latestEntity);
});