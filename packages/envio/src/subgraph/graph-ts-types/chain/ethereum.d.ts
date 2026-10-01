import '../common/eager-offset';
import { Bytes, Wrapped } from '../common/collections';
import { Address, BigInt } from '../common/numbers';
/** Host Ethereum interface */
export declare namespace ethereum {
    function call(call: SmartContractCall): Array<Value> | null;
    function getBalance(address: Address): BigInt;
    function hasCode(address: Address): Wrapped<boolean>;
    function encode(token: Value): Bytes | null;
    function decode(types: string, data: Bytes): Value | null;
}
export declare namespace ethereum {
    /** Type hint for Ethereum values. */
    enum ValueKind {
        ADDRESS = 0,
        FIXED_BYTES = 1,
        BYTES = 2,
        INT = 3,
        UINT = 4,
        BOOL = 5,
        STRING = 6,
        FIXED_ARRAY = 7,
        ARRAY = 8,
        TUPLE = 9
    }
    /**
     * Pointer type for Ethereum value data.
     *
     * Big enough to fit any pointer or native `this.data`.
     */
    type ValuePayload = bigint;
    /**
     * A dynamically typed value used when accessing Ethereum data.
     */
    class Value {
        kind: ValueKind;
        data: ValuePayload;
        constructor(kind: ValueKind, data: ValuePayload);
        lt(_: Value): boolean;
        gt(_: Value): boolean;
        toAddress(): Address;
        toBoolean(): boolean;
        toBytes(): Bytes;
        toI32(): number;
        toBigInt(): BigInt;
        toString(): string;
        toArray(): Array<Value>;
        toTuple(): Tuple;
        toMatrix(): Array<Array<Value>>;
        toTupleArray<T extends Tuple>(): Array<T>;
        toTupleMatrix<T extends Tuple>(): Array<Array<T>>;
        toBooleanArray(): Array<boolean>;
        toBytesArray(): Array<Bytes>;
        toAddressArray(): Array<Address>;
        toStringArray(): Array<string>;
        toI32Array(): Array<number>;
        toBigIntArray(): Array<BigInt>;
        toBooleanMatrix(): Array<Array<boolean>>;
        toBytesMatrix(): Array<Array<Bytes>>;
        toAddressMatrix(): Array<Array<Address>>;
        toStringMatrix(): Array<Array<string>>;
        toI32Matrix(): Array<Array<number>>;
        toBigIntMatrix(): Array<Array<BigInt>>;
        static fromAddress(address: Address): Value;
        static fromBoolean(b: boolean): Value;
        static fromBytes(bytes: Bytes): Value;
        static fromFixedBytes(bytes: Bytes): Value;
        static fromI32(i: number): Value;
        static fromSignedBigInt(i: BigInt): Value;
        static fromUnsignedBigInt(i: BigInt): Value;
        static fromString(s: string): Value;
        static fromArray(values: Array<Value>): Value;
        static fromFixedSizedArray(values: Array<Value>): Value;
        static fromTuple(values: Tuple): Value;
        static fromMatrix(values: Array<Array<Value>>): Value;
        static fromTupleArray(values: Array<Tuple>): Value;
        static fromTupleMatrix(values: Array<Array<Tuple>>): Value;
        static fromBooleanArray(values: Array<boolean>): Value;
        static fromBytesArray(values: Array<Bytes>): Value;
        static fromFixedBytesArray(values: Array<Bytes>): Value;
        static fromAddressArray(values: Array<Address>): Value;
        static fromStringArray(values: Array<string>): Value;
        static fromI32Array(values: Array<number>): Value;
        static fromSignedBigIntArray(values: Array<BigInt>): Value;
        static fromUnsignedBigIntArray(values: Array<BigInt>): Value;
        static fromBooleanMatrix(values: Array<Array<boolean>>): Value;
        static fromBytesMatrix(values: Array<Array<Bytes>>): Value;
        static fromFixedBytesMatrix(values: Array<Array<Bytes>>): Value;
        static fromAddressMatrix(values: Array<Array<Address>>): Value;
        static fromStringMatrix(values: Array<Array<string>>): Value;
        static fromI32Matrix(values: Array<Array<number>>): Value;
        static fromSignedBigIntMatrix(values: Array<Array<BigInt>>): Value;
        static fromUnsignedBigIntMatrix(values: Array<Array<BigInt>>): Value;
    }
    /**
     * Common representation for Ethereum tuples / Solidity structs.
     *
     * This base class stores the tuple/struct values in an array. The Graph CLI
     * code generation then creates subclasses that provide named getters to
     * access the members by name.
     */
    class Tuple extends Array<Value> {
    }
    /**
     * An Ethereum block.
     */
    class Block {
        hash: Bytes;
        parentHash: Bytes;
        unclesHash: Bytes;
        author: Address;
        stateRoot: Bytes;
        transactionsRoot: Bytes;
        receiptsRoot: Bytes;
        number: BigInt;
        gasUsed: BigInt;
        gasLimit: BigInt;
        timestamp: BigInt;
        difficulty: BigInt;
        totalDifficulty: BigInt;
        size: BigInt | null;
        baseFeePerGas: BigInt | null;
        constructor(hash: Bytes, parentHash: Bytes, unclesHash: Bytes, author: Address, stateRoot: Bytes, transactionsRoot: Bytes, receiptsRoot: Bytes, number: BigInt, gasUsed: BigInt, gasLimit: BigInt, timestamp: BigInt, difficulty: BigInt, totalDifficulty: BigInt, size: BigInt | null, baseFeePerGas: BigInt | null);
    }
    /**
     * An Ethereum transaction.
     */
    class Transaction {
        hash: Bytes;
        index: BigInt;
        from: Address;
        to: Address | null;
        value: BigInt;
        gasLimit: BigInt;
        gasPrice: BigInt;
        input: Bytes;
        nonce: BigInt;
        constructor(hash: Bytes, index: BigInt, from: Address, to: Address | null, value: BigInt, gasLimit: BigInt, gasPrice: BigInt, input: Bytes, nonce: BigInt);
    }
    /**
     * An Ethereum transaction receipt.
     */
    class TransactionReceipt {
        transactionHash: Bytes;
        transactionIndex: BigInt;
        blockHash: Bytes;
        blockNumber: BigInt;
        cumulativeGasUsed: BigInt;
        gasUsed: BigInt;
        contractAddress: Address;
        logs: Array<Log>;
        status: BigInt;
        root: Bytes;
        logsBloom: Bytes;
        constructor(transactionHash: Bytes, transactionIndex: BigInt, blockHash: Bytes, blockNumber: BigInt, cumulativeGasUsed: BigInt, gasUsed: BigInt, contractAddress: Address, logs: Array<Log>, status: BigInt, root: Bytes, logsBloom: Bytes);
    }
    /**
     * An Ethereum event log.
     */
    class Log {
        address: Address;
        topics: Array<Bytes>;
        data: Bytes;
        blockHash: Bytes;
        blockNumber: Bytes;
        transactionHash: Bytes;
        transactionIndex: BigInt;
        logIndex: BigInt;
        transactionLogIndex: BigInt;
        logType: string;
        removed: Wrapped<boolean> | null;
        constructor(address: Address, topics: Array<Bytes>, data: Bytes, blockHash: Bytes, blockNumber: Bytes, transactionHash: Bytes, transactionIndex: BigInt, logIndex: BigInt, transactionLogIndex: BigInt, logType: string, removed: Wrapped<boolean> | null);
    }
    /**
     * Common representation for Ethereum smart contract calls.
     */
    class Call {
        to: Address;
        from: Address;
        block: Block;
        transaction: Transaction;
        inputValues: Array<EventParam>;
        outputValues: Array<EventParam>;
        constructor(to: Address, from: Address, block: Block, transaction: Transaction, inputValues: Array<EventParam>, outputValues: Array<EventParam>);
    }
    /**
     * Common representation for Ethereum smart contract events.
     */
    class Event {
        address: Address;
        logIndex: BigInt;
        transactionLogIndex: BigInt;
        logType: string | null;
        block: Block;
        transaction: Transaction;
        parameters: Array<EventParam>;
        receipt: TransactionReceipt | null;
        constructor(address: Address, logIndex: BigInt, transactionLogIndex: BigInt, logType: string | null, block: Block, transaction: Transaction, parameters: Array<EventParam>, receipt: TransactionReceipt | null);
    }
    /**
     * A dynamically-typed Ethereum event parameter.
     */
    class EventParam {
        name: string;
        value: Value;
        constructor(name: string, value: Value);
    }
    class SmartContractCall {
        contractName: string;
        contractAddress: Address;
        functionName: string;
        functionSignature: string;
        functionParams: Array<Value>;
        constructor(contractName: string, contractAddress: Address, functionName: string, functionSignature: string, functionParams: Array<Value>);
    }
    /**
     * Low-level interaction with Ethereum smart contracts
     */
    class SmartContract {
        _name: string;
        _address: Address;
        protected constructor(name: string, address: Address);
        call(name: string, signature: string, params: Array<Value>): Array<Value>;
        tryCall(name: string, signature: string, params: Array<Value>): CallResult<Array<Value>>;
    }
    class CallResult<T> {
        private _value;
        constructor();
        static fromValue<T>(value: T): CallResult<T>;
        get reverted(): boolean;
        get value(): T;
    }
}
