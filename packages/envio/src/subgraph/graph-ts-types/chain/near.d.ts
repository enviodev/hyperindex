import '../common/eager-offset';
import { Bytes } from '../common/collections';
import { BigInt } from '../common/numbers';
export declare namespace near {
    type CryptoHash = Bytes;
    type Account = string;
    type BlockHeight = bigint;
    type Balance = BigInt;
    type Gas = bigint;
    type ShardId = bigint;
    type NumBlocks = bigint;
    type ProtocolVersion = number;
    type Payload = bigint;
    enum CurveKind {
        ED25519 = 0,
        SECP256K1 = 1
    }
    class Signature {
        kind: CurveKind;
        bytes: Bytes;
        constructor(kind: CurveKind, bytes: Bytes);
    }
    class PublicKey {
        kind: CurveKind;
        bytes: Bytes;
        constructor(kind: CurveKind, bytes: Bytes);
    }
    enum AccessKeyPermissionKind {
        FUNCTION_CALL = 0,
        FULL_ACCESS = 1
    }
    class FunctionCallPermission {
        allowance: BigInt;
        receiverId: string;
        methodNames: Array<string>;
        constructor(allowance: BigInt, receiverId: string, methodNames: Array<string>);
    }
    class FullAccessPermission {
    }
    class AccessKeyPermissionValue {
        kind: AccessKeyPermissionKind;
        data: Payload;
        constructor(kind: AccessKeyPermissionKind, data: Payload);
        toFunctionCall(): FunctionCallPermission;
        toFullAccess(): FullAccessPermission;
        static fromFunctionCall(input: FunctionCallPermission): AccessKeyPermissionValue;
        static fromFullAccess(input: FullAccessPermission): AccessKeyPermissionValue;
    }
    class AccessKey {
        nonce: bigint;
        permission: AccessKeyPermissionValue;
        constructor(nonce: bigint, permission: AccessKeyPermissionValue);
    }
    class DataReceiver {
        dataId: CryptoHash;
        receiverId: string;
        constructor(dataId: CryptoHash, receiverId: string);
    }
    enum ActionKind {
        CREATE_ACCOUNT = 0,
        DEPLOY_CONTRACT = 1,
        FUNCTION_CALL = 2,
        TRANSFER = 3,
        STAKE = 4,
        ADD_KEY = 5,
        DELETE_KEY = 6,
        DELETE_ACCOUNT = 7
    }
    class CreateAccountAction {
    }
    class DeployContractAction {
        codeHash: Bytes;
        constructor(codeHash: Bytes);
    }
    class FunctionCallAction {
        methodName: string;
        args: Bytes;
        gas: bigint;
        deposit: BigInt;
        constructor(methodName: string, args: Bytes, gas: bigint, deposit: BigInt);
    }
    class TransferAction {
        deposit: BigInt;
        constructor(deposit: BigInt);
    }
    class StakeAction {
        stake: Balance;
        publicKey: PublicKey;
        constructor(stake: Balance, publicKey: PublicKey);
    }
    class AddKeyAction {
        publicKey: PublicKey;
        accessKey: AccessKey;
        constructor(publicKey: PublicKey, accessKey: AccessKey);
    }
    class DeleteKeyAction {
        publicKey: PublicKey;
        constructor(publicKey: PublicKey);
    }
    class DeleteAccountAction {
        beneficiaryId: Account;
        constructor(beneficiaryId: Account);
    }
    class ActionValue {
        kind: ActionKind;
        data: Payload;
        constructor(kind: ActionKind, data: Payload);
        toCreateAccount(): CreateAccountAction;
        toDeployContract(): DeployContractAction;
        toFunctionCall(): FunctionCallAction;
        toTransfer(): TransferAction;
        toStake(): StakeAction;
        toAddKey(): AddKeyAction;
        toDeleteKey(): DeleteKeyAction;
        toDeleteAccount(): DeleteAccountAction;
        static fromCreateAccount(input: CreateAccountAction): ActionValue;
        static fromDeployContract(input: DeployContractAction): ActionValue;
        static fromFunctionCall(input: FunctionCallAction): ActionValue;
        static fromTransfer(input: TransferAction): ActionValue;
        static fromStake(input: StakeAction): ActionValue;
        static fromAddKey(input: AddKeyAction): ActionValue;
        static fromDeleteKey(input: DeleteKeyAction): ActionValue;
        static fromDeleteAccount(input: DeleteAccountAction): ActionValue;
    }
    class ActionReceipt {
        predecessorId: string;
        receiverId: string;
        id: CryptoHash;
        signerId: string;
        signerPublicKey: PublicKey;
        gasPrice: BigInt;
        outputDataReceivers: Array<DataReceiver>;
        inputDataIds: Array<CryptoHash>;
        actions: Array<ActionValue>;
        constructor(predecessorId: string, receiverId: string, id: CryptoHash, signerId: string, signerPublicKey: PublicKey, gasPrice: BigInt, outputDataReceivers: Array<DataReceiver>, inputDataIds: Array<CryptoHash>, actions: Array<ActionValue>);
    }
    enum SuccessStatusKind {
        VALUE = 0,
        RECEIPT_ID = 1
    }
    class SuccessStatus {
        kind: SuccessStatusKind;
        data: Payload;
        constructor(kind: SuccessStatusKind, data: Payload);
        toValue(): Bytes;
        toReceiptId(): CryptoHash;
        static fromValue(input: Bytes): SuccessStatus;
        static fromReceiptId(input: CryptoHash): SuccessStatus;
    }
    enum Direction {
        LEFT = 0,
        RIGHT = 1
    }
    class MerklePathItem {
        hash: CryptoHash;
        direction: Direction;
        constructor(hash: CryptoHash, direction: Direction);
        lt(_: MerklePathItem): boolean;
        gt(_: MerklePathItem): boolean;
        toString(): string;
    }
    class MerklePath extends Array<MerklePathItem> {
    }
    class ExecutionOutcome {
        gasBurnt: bigint;
        proof: MerklePath;
        blockHash: CryptoHash;
        id: CryptoHash;
        logs: Array<string>;
        receiptIds: Array<CryptoHash>;
        tokensBurnt: BigInt;
        executorId: string;
        status: SuccessStatus;
        constructor(gasBurnt: bigint, proof: MerklePath, blockHash: CryptoHash, id: CryptoHash, logs: Array<string>, receiptIds: Array<CryptoHash>, tokensBurnt: BigInt, executorId: string, status: SuccessStatus);
    }
    class SlashedValidator {
        account: Account;
        isDoubleSign: boolean;
        constructor(account: Account, isDoubleSign: boolean);
    }
    class BlockHeader {
        height: BlockHeight;
        prevHeight: BlockHeight;
        blockOrdinal: NumBlocks;
        epochId: CryptoHash;
        nextEpochId: CryptoHash;
        chunksIncluded: bigint;
        hash: CryptoHash;
        prevHash: CryptoHash;
        timestampNanosec: bigint;
        prevStateRoot: CryptoHash;
        chunkReceiptsRoot: CryptoHash;
        chunkHeadersRoot: CryptoHash;
        chunkTxRoot: CryptoHash;
        outcomeRoot: CryptoHash;
        challengesRoot: CryptoHash;
        randomValue: CryptoHash;
        validatorProposals: Array<ValidatorStake>;
        chunkMask: Array<boolean>;
        gasPrice: Balance;
        totalSupply: Balance;
        challengesResult: Array<SlashedValidator>;
        lastFinalBlock: CryptoHash;
        lastDsFinalBlock: CryptoHash;
        nextBpHash: CryptoHash;
        blockMerkleRoot: CryptoHash;
        epochSyncDataHash: CryptoHash;
        approvals: Array<Signature>;
        signature: Signature;
        latestProtocolVersion: ProtocolVersion;
        constructor(height: BlockHeight, prevHeight: BlockHeight, // Always zero when version < V3
        blockOrdinal: NumBlocks, // Always zero when version < V3
        epochId: CryptoHash, nextEpochId: CryptoHash, chunksIncluded: bigint, hash: CryptoHash, prevHash: CryptoHash, timestampNanosec: bigint, prevStateRoot: CryptoHash, chunkReceiptsRoot: CryptoHash, chunkHeadersRoot: CryptoHash, chunkTxRoot: CryptoHash, outcomeRoot: CryptoHash, challengesRoot: CryptoHash, randomValue: CryptoHash, validatorProposals: Array<ValidatorStake>, chunkMask: Array<boolean>, gasPrice: Balance, totalSupply: Balance, challengesResult: Array<SlashedValidator>, lastFinalBlock: CryptoHash, lastDsFinalBlock: CryptoHash, nextBpHash: CryptoHash, blockMerkleRoot: CryptoHash, epochSyncDataHash: CryptoHash, // Always empty when version < V3
        approvals: Array<Signature>, // Array<Option<Signature>>
        signature: Signature, latestProtocolVersion: ProtocolVersion);
    }
    class ValidatorStake {
        account: Account;
        publicKey: PublicKey;
        stake: Balance;
        constructor(account: Account, publicKey: PublicKey, stake: Balance);
    }
    class ChunkHeader {
        encodedLength: bigint;
        gasUsed: Gas;
        gasLimit: Gas;
        shardId: ShardId;
        heightCreated: BlockHeight;
        heightIncluded: BlockHeight;
        chunkHash: CryptoHash;
        signature: Signature;
        prevBlockHash: CryptoHash;
        prevStateRoot: CryptoHash;
        encodedMerkleRoot: CryptoHash;
        balanceBurnt: Balance;
        outgoingReceiptsRoot: CryptoHash;
        txRoot: CryptoHash;
        validatorProposals: Array<ValidatorStake>;
        constructor(encodedLength: bigint, gasUsed: Gas, gasLimit: Gas, shardId: ShardId, heightCreated: BlockHeight, heightIncluded: BlockHeight, chunkHash: CryptoHash, signature: Signature, prevBlockHash: CryptoHash, prevStateRoot: CryptoHash, encodedMerkleRoot: CryptoHash, balanceBurnt: Balance, outgoingReceiptsRoot: CryptoHash, txRoot: CryptoHash, validatorProposals: Array<ValidatorStake>);
    }
    class Block {
        author: Account;
        header: BlockHeader;
        chunks: Array<ChunkHeader>;
        constructor(author: Account, header: BlockHeader, chunks: Array<ChunkHeader>);
    }
    class ReceiptWithOutcome {
        outcome: ExecutionOutcome;
        receipt: ActionReceipt;
        block: Block;
        constructor(outcome: ExecutionOutcome, receipt: ActionReceipt, block: Block);
    }
}
