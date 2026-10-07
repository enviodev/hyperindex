import '../common/eager-offset';
import { Bytes } from '../common/collections';
export declare namespace cosmos {
    class Block {
        header: Header;
        evidence: EvidenceList;
        lastCommit: Commit;
        resultBeginBlock: ResponseBeginBlock;
        resultEndBlock: ResponseEndBlock;
        transactions: Array<TxResult>;
        validatorUpdates: Array<Validator>;
        constructor(header: Header, evidence: EvidenceList, lastCommit: Commit, resultBeginBlock: ResponseBeginBlock, resultEndBlock: ResponseEndBlock, transactions: Array<TxResult>, validatorUpdates: Array<Validator>);
    }
    class HeaderOnlyBlock {
        header: Header;
        constructor(header: Header);
    }
    class EventData {
        event: Event;
        block: HeaderOnlyBlock;
        tx: TransactionContext;
        constructor(event: Event, block: HeaderOnlyBlock, tx: TransactionContext);
    }
    class TransactionData {
        tx: TxResult;
        block: HeaderOnlyBlock;
        constructor(tx: TxResult, block: HeaderOnlyBlock);
    }
    class MessageData {
        message: Any;
        block: HeaderOnlyBlock;
        tx: TransactionContext;
        constructor(message: Any, block: HeaderOnlyBlock, tx: TransactionContext);
    }
    class TransactionContext {
        hash: Bytes;
        index: number;
        code: number;
        gasWanted: bigint;
        gasUsed: bigint;
        constructor(hash: Bytes, index: number, code: number, gasWanted: bigint, gasUsed: bigint);
    }
    class Header {
        version: Consensus;
        chainId: string;
        height: bigint;
        time: Timestamp;
        lastBlockId: BlockID;
        lastCommitHash: Bytes;
        dataHash: Bytes;
        validatorsHash: Bytes;
        nextValidatorsHash: Bytes;
        consensusHash: Bytes;
        appHash: Bytes;
        lastResultsHash: Bytes;
        evidenceHash: Bytes;
        proposerAddress: Bytes;
        hash: Bytes;
        constructor(version: Consensus, chainId: string, height: bigint, time: Timestamp, lastBlockId: BlockID, lastCommitHash: Bytes, dataHash: Bytes, validatorsHash: Bytes, nextValidatorsHash: Bytes, consensusHash: Bytes, appHash: Bytes, lastResultsHash: Bytes, evidenceHash: Bytes, proposerAddress: Bytes, hash: Bytes);
    }
    class Consensus {
        block: bigint;
        app: bigint;
        constructor(block: bigint, app: bigint);
    }
    class Timestamp {
        seconds: bigint;
        nanos: number;
        constructor(seconds: bigint, nanos: number);
    }
    class BlockID {
        hash: Bytes;
        partSetHeader: PartSetHeader;
        constructor(hash: Bytes, partSetHeader: PartSetHeader);
    }
    class PartSetHeader {
        total: number;
        hash: Bytes;
        constructor(total: number, hash: Bytes);
    }
    class EvidenceList {
        evidence: Array<Evidence>;
        constructor(evidence: Array<Evidence>);
    }
    class Evidence {
        duplicateVoteEvidence: DuplicateVoteEvidence;
        lightClientAttackEvidence: LightClientAttackEvidence;
        constructor(duplicateVoteEvidence: DuplicateVoteEvidence, lightClientAttackEvidence: LightClientAttackEvidence);
    }
    class DuplicateVoteEvidence {
        voteA: EventVote;
        voteB: EventVote;
        totalVotingPower: bigint;
        validatorPower: bigint;
        timestamp: Timestamp;
        constructor(voteA: EventVote, voteB: EventVote, totalVotingPower: bigint, validatorPower: bigint, timestamp: Timestamp);
    }
    class EventVote {
        eventVoteType: SignedMsgType;
        height: bigint;
        round: number;
        blockId: BlockID;
        timestamp: Timestamp;
        validatorAddress: Bytes;
        validatorIndex: number;
        signature: Bytes;
        constructor(eventVoteType: SignedMsgType, height: bigint, round: number, blockId: BlockID, timestamp: Timestamp, validatorAddress: Bytes, validatorIndex: number, signature: Bytes);
    }
    enum SignedMsgType {
        SIGNED_MSG_TYPE_UNKNOWN = 0,
        SIGNED_MSG_TYPE_PREVOTE = 1,
        SIGNED_MSG_TYPE_PRECOMMIT = 2,
        SIGNED_MSG_TYPE_PROPOSAL = 32
    }
    class LightClientAttackEvidence {
        conflictingBlock: LightBlock;
        commonHeight: bigint;
        byzantineValidators: Array<Validator>;
        totalVotingPower: bigint;
        timestamp: Timestamp;
        constructor(conflictingBlock: LightBlock, commonHeight: bigint, byzantineValidators: Array<Validator>, totalVotingPower: bigint, timestamp: Timestamp);
    }
    class LightBlock {
        signedHeader: SignedHeader;
        validatorSet: ValidatorSet;
        constructor(signedHeader: SignedHeader, validatorSet: ValidatorSet);
    }
    class SignedHeader {
        header: Header;
        commit: Commit;
        constructor(header: Header, commit: Commit);
    }
    class Commit {
        height: bigint;
        round: number;
        blockId: BlockID;
        signatures: Array<CommitSig>;
        constructor(height: bigint, round: number, blockId: BlockID, signatures: Array<CommitSig>);
    }
    class CommitSig {
        blockIdFlag: BlockIDFlag;
        validatorAddress: Bytes;
        timestamp: Timestamp;
        signature: Bytes;
        constructor(blockIdFlag: BlockIDFlag, validatorAddress: Bytes, timestamp: Timestamp, signature: Bytes);
    }
    enum BlockIDFlag {
        BLOCK_ID_FLAG_UNKNOWN = 0,
        BLOCK_ID_FLAG_ABSENT = 1,
        BLOCK_ID_FLAG_COMMIT = 2,
        BLOCK_ID_FLAG_NIL = 3
    }
    class ValidatorSet {
        validators: Array<Validator>;
        proposer: Validator;
        totalVotingPower: bigint;
        constructor(validators: Array<Validator>, proposer: Validator, totalVotingPower: bigint);
    }
    class Validator {
        address: Bytes;
        pubKey: PublicKey;
        votingPower: bigint;
        proposerPriority: bigint;
        constructor(address: Bytes, pubKey: PublicKey, votingPower: bigint, proposerPriority: bigint);
    }
    class PublicKey {
        ed25519: Bytes;
        secp256k1: Bytes;
        constructor(ed25519: Bytes, secp256k1: Bytes);
    }
    class ResponseBeginBlock {
        events: Array<Event>;
        constructor(events: Array<Event>);
    }
    class Event {
        eventType: string;
        attributes: Array<EventAttribute>;
        constructor(eventType: string, attributes: Array<EventAttribute>);
        getAttribute(key: string): EventAttribute | null;
        getAttributeValue(key: string): string;
    }
    class EventAttribute {
        key: string;
        value: string;
        index: boolean;
        constructor(key: string, value: string, index: boolean);
    }
    class ResponseEndBlock {
        validatorUpdates: Array<ValidatorUpdate>;
        consensusParamUpdates: ConsensusParams;
        events: Array<Event>;
        constructor(validatorUpdates: Array<ValidatorUpdate>, consensusParamUpdates: ConsensusParams, events: Array<Event>);
    }
    class ValidatorUpdate {
        address: Bytes;
        pubKey: PublicKey;
        power: bigint;
        constructor(address: Bytes, pubKey: PublicKey, power: bigint);
    }
    class ConsensusParams {
        block: BlockParams;
        evidence: EvidenceParams;
        validator: ValidatorParams;
        version: VersionParams;
        constructor(block: BlockParams, evidence: EvidenceParams, validator: ValidatorParams, version: VersionParams);
    }
    class BlockParams {
        maxBytes: bigint;
        maxGas: bigint;
        constructor(maxBytes: bigint, maxGas: bigint);
    }
    class EvidenceParams {
        maxAgeNumBlocks: bigint;
        maxAgeDuration: Duration;
        maxBytes: bigint;
        constructor(maxAgeNumBlocks: bigint, maxAgeDuration: Duration, maxBytes: bigint);
    }
    class Duration {
        seconds: bigint;
        nanos: number;
        constructor(seconds: bigint, nanos: number);
    }
    class ValidatorParams {
        pubKeyTypes: Array<string>;
        constructor(pubKeyTypes: Array<string>);
    }
    class VersionParams {
        appVersion: bigint;
        constructor(appVersion: bigint);
    }
    class TxResult {
        height: bigint;
        index: number;
        tx: Tx;
        result: ResponseDeliverTx;
        hash: Bytes;
        constructor(height: bigint, index: number, tx: Tx, result: ResponseDeliverTx, hash: Bytes);
    }
    class Tx {
        body: TxBody;
        authInfo: AuthInfo;
        signatures: Array<Bytes>;
        constructor(body: TxBody, authInfo: AuthInfo, signatures: Array<Bytes>);
    }
    class TxBody {
        messages: Array<Any>;
        memo: string;
        timeoutHeight: bigint;
        extensionOptions: Array<Any>;
        nonCriticalExtensionOptions: Array<Any>;
        constructor(messages: Array<Any>, memo: string, timeoutHeight: bigint, extensionOptions: Array<Any>, nonCriticalExtensionOptions: Array<Any>);
    }
    class Any {
        typeUrl: string;
        value: Bytes;
        constructor(typeUrl: string, value: Bytes);
    }
    class AuthInfo {
        signerInfos: Array<SignerInfo>;
        fee: Fee;
        tip: Tip;
        constructor(signerInfos: Array<SignerInfo>, fee: Fee, tip: Tip);
    }
    class SignerInfo {
        publicKey: Any;
        modeInfo: ModeInfo;
        sequence: bigint;
        constructor(publicKey: Any, modeInfo: ModeInfo, sequence: bigint);
    }
    class ModeInfo {
        single: ModeInfoSingle;
        multi: ModeInfoMulti;
        constructor(single: ModeInfoSingle, multi: ModeInfoMulti);
    }
    class ModeInfoSingle {
        mode: SignMode;
        constructor(mode: SignMode);
    }
    enum SignMode {
        SIGN_MODE_UNSPECIFIED = 0,
        SIGN_MODE_DIRECT = 1,
        SIGN_MODE_TEXTUAL = 2,
        SIGN_MODE_LEGACY_AMINO_JSON = 127
    }
    class ModeInfoMulti {
        bitarray: CompactBitArray;
        modeInfos: Array<ModeInfo>;
        constructor(bitarray: CompactBitArray, modeInfos: Array<ModeInfo>);
    }
    class CompactBitArray {
        extraBitsStored: number;
        elems: Bytes;
        constructor(extraBitsStored: number, elems: Bytes);
    }
    class Fee {
        amount: Array<Coin>;
        gasLimit: bigint;
        payer: string;
        granter: string;
        constructor(amount: Array<Coin>, gasLimit: bigint, payer: string, granter: string);
    }
    class Coin {
        denom: string;
        amount: string;
        constructor(denom: string, amount: string);
    }
    class Tip {
        amount: Array<Coin>;
        tipper: string;
        constructor(amount: Array<Coin>, tipper: string);
    }
    class ResponseDeliverTx {
        code: number;
        data: Bytes;
        log: string;
        info: string;
        gasWanted: bigint;
        gasUsed: bigint;
        events: Array<Event>;
        codespace: string;
        constructor(code: number, data: Bytes, log: string, info: string, gasWanted: bigint, gasUsed: bigint, events: Array<Event>, codespace: string);
    }
    class ValidatorSetUpdates {
        validatorUpdates: Array<Validator>;
        constructor(validatorUpdates: Array<Validator>);
    }
}
