import { ByteArray, Bytes, Entity } from './common/collections';
import { Value } from './common/value';
export * from './chain/arweave';
export * from './chain/ethereum';
export * from './chain/near';
export * from './chain/cosmos';
export * from './chain/starknet';
export * from './common/collections';
export * from './common/conversion';
export * from './common/datasource';
export * from './common/json';
export * from './common/numbers';
export * from './common/value';
export * from './common/yaml';
/**
 * Host store interface.
 */
export declare namespace store {
    function get(entity: string, id: string): Entity | null;
    /** If the entity was not created in the block, this function will return null. */
    function get_in_block(entity: string, id: string): Entity | null;
    function loadRelated(entity: string, id: string, field: string): Array<Entity>;
    function set(entity: string, id: string, data: Entity): void;
    function remove(entity: string, id: string): void;
}
/** Host IPFS interface */
export declare namespace ipfs {
    function cat(hash: string): Bytes | null;
    function map(hash: string, callback: string, userData: Value, flags: string[]): void;
}
export declare namespace ipfs {
    function mapJSON(hash: string, callback: string, userData: Value): void;
}
/** Host crypto utilities interface */
export declare namespace crypto {
    function keccak256(input: ByteArray): ByteArray;
}
/**
 * Special function for ENS name lookups, not meant for general purpose use.
 * This function will only be useful if the graph-node instance has additional
 * data loaded **
 */
export declare namespace ens {
    function nameByHash(hash: string): string | null;
}
export declare namespace log {
    function log(level: Level, msg: string): void;
}
export declare namespace log {
    enum Level {
        CRITICAL = 0,
        ERROR = 1,
        WARNING = 2,
        INFO = 3,
        DEBUG = 4
    }
    /**
     * Logs a critical message that terminates the subgraph.
     *
     * @param msg Format string a la "Value = {}, other = {}".
     * @param args Format string arguments.
     */
    function critical(msg: string, args: Array<string>): void;
    /**
     * Logs an error message.
     *
     * @param msg Format string a la "Value = {}, other = {}".
     * @param args Format string arguments.
     */
    function error(msg: string, args: Array<string>): void;
    /** Logs a warning message.
     *
     * @param msg Format string a la "Value = {}, other = {}".
     * @param args Format string arguments.
     */
    function warning(msg: string, args: Array<string>): void;
    /** Logs an info message.
     *
     * @param msg Format string a la "Value = {}, other = {}".
     * @param args Format string arguments.
     */
    function info(msg: string, args: Array<string>): void;
    /** Logs a debug message.
     *
     * @param msg Format string a la "Value = {}, other = {}".
     * @param args Format string arguments.
     */
    function debug(msg: string, args: Array<string>): void;
}
/**
 * Helper functions for Ethereum.
 */
export declare namespace EthereumUtils {
    /**
     * Returns the contract address that would result from the given CREATE2 call.
     * @param from The Ethereum address of the account that is initiating the contract creation.
     * @param salt A 32-byte value that is used to create a deterministic address for the contract. This can be any arbitrary value, but it should be unique to the contract being created.
     * @param initCodeHash he compiled code that will be executed when the contract is created. This should be a hex-encoded string that represents the compiled bytecode.
     * @returns Address of the contract that would be created.
     */
    function getCreate2Address(from: Bytes, salt: Bytes, initCodeHash: Bytes): Bytes;
}
