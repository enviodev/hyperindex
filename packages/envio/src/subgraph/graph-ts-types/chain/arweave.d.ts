import '../common/eager-offset';
import { Bytes } from '../common/collections';
export declare namespace arweave {
    /**
     * A key-value pair for arbitrary metadata
     */
    class Tag {
        name: Bytes;
        value: Bytes;
        constructor(name: Bytes, value: Bytes);
    }
    class ProofOfAccess {
        option: string;
        txPath: Bytes;
        dataPath: Bytes;
        chunk: Bytes;
        constructor(option: string, txPath: Bytes, dataPath: Bytes, chunk: Bytes);
    }
    /**
     * An Arweave block.
     */
    class Block {
        timestamp: bigint;
        lastRetarget: bigint;
        height: bigint;
        indepHash: Bytes;
        nonce: Bytes;
        previousBlock: Bytes;
        diff: Bytes;
        hash: Bytes;
        txRoot: Bytes;
        txs: Bytes[];
        walletList: Bytes;
        rewardAddr: Bytes;
        tags: Tag[];
        rewardPool: Bytes;
        weaveSize: Bytes;
        blockSize: Bytes;
        cumulativeDiff: Bytes;
        hashListMerkle: Bytes;
        poa: ProofOfAccess;
        constructor(timestamp: bigint, lastRetarget: bigint, height: bigint, indepHash: Bytes, nonce: Bytes, previousBlock: Bytes, diff: Bytes, hash: Bytes, txRoot: Bytes, txs: Bytes[], walletList: Bytes, rewardAddr: Bytes, tags: Tag[], rewardPool: Bytes, weaveSize: Bytes, blockSize: Bytes, cumulativeDiff: Bytes, hashListMerkle: Bytes, poa: ProofOfAccess);
    }
    /**
     * An Arweave transaction
     */
    class Transaction {
        format: number;
        id: Bytes;
        lastTx: Bytes;
        owner: Bytes;
        tags: Tag[];
        target: Bytes;
        quantity: Bytes;
        data: Bytes;
        dataSize: Bytes;
        dataRoot: Bytes;
        signature: Bytes;
        reward: Bytes;
        constructor(format: number, id: Bytes, lastTx: Bytes, owner: Bytes, tags: Tag[], target: Bytes, quantity: Bytes, data: Bytes, dataSize: Bytes, dataRoot: Bytes, signature: Bytes, reward: Bytes);
    }
    /**
     * An Arweave transaction with block ptr
     */
    class TransactionWithBlockPtr {
        tx: Transaction;
        block: Block;
        constructor(tx: Transaction, block: Block);
    }
}
