import '../common/eager-offset';
import { Bytes } from '../common/collections';
import { BigInt } from '../common/numbers';
export declare namespace starknet {
    class Block {
        number: BigInt;
        hash: Bytes;
        prevHash: Bytes;
        timestamp: BigInt;
        constructor(number: BigInt, hash: Bytes, prevHash: Bytes, timestamp: BigInt);
    }
    class Transaction {
        type: TransactionType;
        hash: Bytes;
        constructor(type: TransactionType, hash: Bytes);
    }
    enum TransactionType {
        DEPLOY = 0,
        INVOKE_FUNCTION = 1,
        DECLARE = 2,
        L1_HANDLER = 3,
        DEPLOY_ACCOUNT = 4
    }
    class Event {
        fromAddr: Bytes;
        keys: Array<Bytes>;
        data: Array<Bytes>;
        block: Block;
        transaction: Transaction;
        constructor(fromAddr: Bytes, keys: Array<Bytes>, data: Array<Bytes>, block: Block, transaction: Transaction);
    }
}
