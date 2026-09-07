import { ByteArray } from './index';
/**
 * Takes 2 ByteArrays and concatenates them
 * @param a - 1st ByteArray
 * @param b - 2nd ByteArray
 * @returns A concatenated ByteArray
 */
export declare function concat(a: ByteArray, b: ByteArray): ByteArray;
/**
 * Parses a CSV string into an array of strings.
 * @param csv CSV string.
 * @returns Array of strings.
 */
export declare function parseCSV(csv: string): Array<string>;
/**
 * Adds 0x1220 to the front of a ByteArray. This can be used when an IPFS hash is stored in an Ethereum Bytes32 type.
 * The IPFS hash will fit in a Bytes32 when 0x1220 is removed. Since 0x1220 is currently in front of every single IPFS
 * hash, this works. But it is possible in the future that IPFS will update their spec.
 * @param a - The ByteArray without 0x1220 prefixed
 * @returns - The ByteArray with 0x1220 prefixed
 */
export declare function addQm(a: ByteArray): ByteArray;
