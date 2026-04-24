//*************
//**CONTRACTS**
//*************

module Transaction = {
  type t = {
    transactionIndex: int,
    hash: string,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - from")
    from?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - to")
    to?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - gas")
    gas?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - gasPrice")
    gasPrice?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - maxPriorityFeePerGas")
    maxPriorityFeePerGas?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - maxFeePerGas")
    maxFeePerGas?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - cumulativeGasUsed")
    cumulativeGasUsed?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - effectiveGasPrice")
    effectiveGasPrice?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - gasUsed")
    gasUsed?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - input")
    input?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - nonce")
    nonce?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - value")
    value?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - v")
    v?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - r")
    r?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - s")
    s?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - contractAddress")
    contractAddress?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - logsBloom")
    logsBloom?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - root")
    root?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - status")
    status?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - yParity")
    yParity?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - accessList")
    accessList?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - maxFeePerBlobGas")
    maxFeePerBlobGas?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - blobVersionedHashes")
    blobVersionedHashes?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - type")
    type_?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - l1Fee")
    l1Fee?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - l1GasPrice")
    l1GasPrice?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - l1GasUsed")
    l1GasUsed?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - l1FeeScalar")
    l1FeeScalar?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - gasUsedForL1")
    gasUsedForL1?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      transaction_fields:\n        - authorizationList")
    authorizationList?: unit,
}
}

module Block = {
  type t = {
    number: int,
    timestamp: int,
    hash: string,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - parentHash")
    parentHash?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - nonce")
    nonce?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - sha3Uncles")
    sha3Uncles?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - logsBloom")
    logsBloom?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - transactionsRoot")
    transactionsRoot?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - stateRoot")
    stateRoot?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - receiptsRoot")
    receiptsRoot?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - miner")
    miner?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - difficulty")
    difficulty?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - totalDifficulty")
    totalDifficulty?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - extraData")
    extraData?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - size")
    size?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - gasLimit")
    gasLimit?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - gasUsed")
    gasUsed?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - uncles")
    uncles?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - baseFeePerGas")
    baseFeePerGas?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - blobGasUsed")
    blobGasUsed?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - excessBlobGas")
    excessBlobGas?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - parentBeaconBlockRoot")
    parentBeaconBlockRoot?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - withdrawalsRoot")
    withdrawalsRoot?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - l1BlockNumber")
    l1BlockNumber?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - sendCount")
    sendCount?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - sendRoot")
    sendRoot?: unit,
    @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: global\n    field_selection:\n      block_fields:\n        - mixHash")
    mixHash?: unit,
}
}

module SingleOrMultiple: {
  type t<'a>
  let normalizeOrThrow: (t<'a>, ~nestedArrayDepth: int=?) => array<'a>
  let single: 'a => t<'a>
  let multiple: array<'a> => t<'a>
} = {
  type t<'a> = JSON.t

  external single: 'a => t<'a> = "%identity"
  external multiple: array<'a> => t<'a> = "%identity"
  external castMultiple: t<'a> => array<'a> = "%identity"
  external castSingle: t<'a> => 'a = "%identity"

  exception AmbiguousEmptyNestedArray

  let rec isMultiple = (t: t<'a>, ~nestedArrayDepth): bool =>
    if !Array.isArray(t) {
      false
    } else {
      let arr = t->(Utils.magic: t<'a> => array<t<'a>>)
      if nestedArrayDepth == 0 {
        true
      } else if arr->Array.length == 0 {
        AmbiguousEmptyNestedArray->ErrorHandling.mkLogAndRaise(
          ~msg="The given empty array could be interpreted as a flat array (value) or nested array. Since it's ambiguous,
          please pass in a nested empty array if the intention is to provide an empty array as a value",
        )
      } else {
        arr->Utils.Array.firstUnsafe->isMultiple(~nestedArrayDepth=nestedArrayDepth - 1)
      }
    }

  let normalizeOrThrow = (t: t<'a>, ~nestedArrayDepth=0): array<'a> => {
    if t->isMultiple(~nestedArrayDepth) {
      t->castMultiple
    } else {
      [t->castSingle]
    }
  }
}

/** Options for onEvent / contractRegister. */
type onEventOptions<'eventIdentity, 'where> = {
  event: 'eventIdentity,
  wildcard?: bool,
  where?: 'where,
}

module Enums = {
  module AccountType = {
    type t =
      | @as("ADMIN") ADMIN
      | @as("USER") USER
  }
  module GravatarSize = {
    type t =
      | @as("SMALL") SMALL
      | @as("MEDIUM") MEDIUM
      | @as("LARGE") LARGE
  }
}

module Entities = {
  type id = string

  module A = {
    type t = {id: id, b_id: id, optionalStringToTestLinkedEntities: option<string>}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("b_id") b?: Envio.whereOperator<id>, @as("optionalStringToTestLinkedEntities") optionalStringToTestLinkedEntities?: Envio.whereOperator<option<string>>}
  }

  module B = {
    type t = {id: id, c_id: option<id>}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("c_id") c?: Envio.whereOperator<option<id>>}
  }

  module C = {
    type t = {id: id, a_id: id, stringThatIsMirroredToA: string}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("a_id") a?: Envio.whereOperator<id>, @as("stringThatIsMirroredToA") stringThatIsMirroredToA?: Envio.whereOperator<string>}
  }

  module CustomSelectionTestPass = {
    type t = {id: id}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>}
  }

  module D = {
    type t = {id: id, c: id}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("c") c?: Envio.whereOperator<id>}
  }

  module EntityWith63LenghtName______________________________________one = {
    type t = {id: id}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>}
  }

  module EntityWith63LenghtName______________________________________two = {
    type t = {id: id}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>}
  }

  module EntityWithAllNonArrayTypes = {
    type t = {id: id, string: string, optString: option<string>, int_: int, optInt: option<int>, float_: float, optFloat: option<float>, bool: bool, optBool: option<bool>, bigInt: bigint, optBigInt: option<bigint>, bigDecimal: BigDecimal.t, optBigDecimal: option<BigDecimal.t>, bigDecimalWithConfig: BigDecimal.t, enumField: Enums.AccountType.t, optEnumField: option<Enums.AccountType.t>, timestamp: Date.t, optTimestamp: option<Date.t>}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("string") string?: Envio.whereOperator<string>, @as("optString") optString?: Envio.whereOperator<option<string>>, @as("int_") int_?: Envio.whereOperator<int>, @as("optInt") optInt?: Envio.whereOperator<option<int>>, @as("float_") float_?: Envio.whereOperator<float>, @as("optFloat") optFloat?: Envio.whereOperator<option<float>>, @as("bool") bool?: Envio.whereOperator<bool>, @as("optBool") optBool?: Envio.whereOperator<option<bool>>, @as("bigInt") bigInt?: Envio.whereOperator<bigint>, @as("optBigInt") optBigInt?: Envio.whereOperator<option<bigint>>, @as("bigDecimal") bigDecimal?: Envio.whereOperator<BigDecimal.t>, @as("optBigDecimal") optBigDecimal?: Envio.whereOperator<option<BigDecimal.t>>, @as("bigDecimalWithConfig") bigDecimalWithConfig?: Envio.whereOperator<BigDecimal.t>, @as("enumField") enumField?: Envio.whereOperator<Enums.AccountType.t>, @as("optEnumField") optEnumField?: Envio.whereOperator<option<Enums.AccountType.t>>, @as("timestamp") timestamp?: Envio.whereOperator<Date.t>, @as("optTimestamp") optTimestamp?: Envio.whereOperator<option<Date.t>>}
  }

  module EntityWithAllTypes = {
    type t = {id: id, string: string, optString: option<string>, arrayOfStrings: array<string>, int_: int, optInt: option<int>, arrayOfInts: array<int>, float_: float, optFloat: option<float>, arrayOfFloats: array<float>, bool: bool, optBool: option<bool>, bigInt: bigint, optBigInt: option<bigint>, arrayOfBigInts: array<bigint>, bigDecimal: BigDecimal.t, optBigDecimal: option<BigDecimal.t>, bigDecimalWithConfig: BigDecimal.t, arrayOfBigDecimals: array<BigDecimal.t>, timestamp: Date.t, optTimestamp: option<Date.t>, json: JSON.t, enumField: Enums.AccountType.t, optEnumField: option<Enums.AccountType.t>}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("string") string?: Envio.whereOperator<string>, @as("optString") optString?: Envio.whereOperator<option<string>>, @as("arrayOfStrings") arrayOfStrings?: Envio.whereOperator<array<string>>, @as("int_") int_?: Envio.whereOperator<int>, @as("optInt") optInt?: Envio.whereOperator<option<int>>, @as("arrayOfInts") arrayOfInts?: Envio.whereOperator<array<int>>, @as("float_") float_?: Envio.whereOperator<float>, @as("optFloat") optFloat?: Envio.whereOperator<option<float>>, @as("arrayOfFloats") arrayOfFloats?: Envio.whereOperator<array<float>>, @as("bool") bool?: Envio.whereOperator<bool>, @as("optBool") optBool?: Envio.whereOperator<option<bool>>, @as("bigInt") bigInt?: Envio.whereOperator<bigint>, @as("optBigInt") optBigInt?: Envio.whereOperator<option<bigint>>, @as("arrayOfBigInts") arrayOfBigInts?: Envio.whereOperator<array<bigint>>, @as("bigDecimal") bigDecimal?: Envio.whereOperator<BigDecimal.t>, @as("optBigDecimal") optBigDecimal?: Envio.whereOperator<option<BigDecimal.t>>, @as("bigDecimalWithConfig") bigDecimalWithConfig?: Envio.whereOperator<BigDecimal.t>, @as("arrayOfBigDecimals") arrayOfBigDecimals?: Envio.whereOperator<array<BigDecimal.t>>, @as("timestamp") timestamp?: Envio.whereOperator<Date.t>, @as("optTimestamp") optTimestamp?: Envio.whereOperator<option<Date.t>>, @as("json") json?: Envio.whereOperator<JSON.t>, @as("enumField") enumField?: Envio.whereOperator<Enums.AccountType.t>, @as("optEnumField") optEnumField?: Envio.whereOperator<option<Enums.AccountType.t>>}
  }

  module EntityWithBigDecimal = {
    type t = {id: id, bigDecimal: BigDecimal.t}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("bigDecimal") bigDecimal?: Envio.whereOperator<BigDecimal.t>}
  }

  module EntityWithRestrictedReScriptField = {
    type t = {id: id, @as("type") type_: string}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("type") type_?: Envio.whereOperator<string>}
  }

  module EntityWithTimestamp = {
    type t = {id: id, timestamp: Date.t}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("timestamp") timestamp?: Envio.whereOperator<Date.t>}
  }

  module Gravatar = {
    type t = {id: id, owner_id: id, displayName: string, imageUrl: string, updatesCount: bigint, size: Enums.GravatarSize.t}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("owner_id") owner?: Envio.whereOperator<id>, @as("displayName") displayName?: Envio.whereOperator<string>, @as("imageUrl") imageUrl?: Envio.whereOperator<string>, @as("updatesCount") updatesCount?: Envio.whereOperator<bigint>, @as("size") size?: Envio.whereOperator<Enums.GravatarSize.t>}
  }

  module NftCollection = {
    type t = {id: id, contractAddress: string, name: string, symbol: string, maxSupply: bigint, currentSupply: int}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("contractAddress") contractAddress?: Envio.whereOperator<string>, @as("name") name?: Envio.whereOperator<string>, @as("symbol") symbol?: Envio.whereOperator<string>, @as("maxSupply") maxSupply?: Envio.whereOperator<bigint>, @as("currentSupply") currentSupply?: Envio.whereOperator<int>}
  }

  module PostgresNumericPrecisionEntityTester = {
    type t = {id: id, exampleBigInt: option<bigint>, exampleBigIntRequired: bigint, exampleBigIntArray: option<array<bigint>>, exampleBigIntArrayRequired: array<bigint>, exampleBigDecimal: option<BigDecimal.t>, exampleBigDecimalRequired: BigDecimal.t, exampleBigDecimalArray: option<array<BigDecimal.t>>, exampleBigDecimalArrayRequired: array<BigDecimal.t>, exampleBigDecimalOtherOrder: BigDecimal.t}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("exampleBigInt") exampleBigInt?: Envio.whereOperator<option<bigint>>, @as("exampleBigIntRequired") exampleBigIntRequired?: Envio.whereOperator<bigint>, @as("exampleBigIntArray") exampleBigIntArray?: Envio.whereOperator<option<array<bigint>>>, @as("exampleBigIntArrayRequired") exampleBigIntArrayRequired?: Envio.whereOperator<array<bigint>>, @as("exampleBigDecimal") exampleBigDecimal?: Envio.whereOperator<option<BigDecimal.t>>, @as("exampleBigDecimalRequired") exampleBigDecimalRequired?: Envio.whereOperator<BigDecimal.t>, @as("exampleBigDecimalArray") exampleBigDecimalArray?: Envio.whereOperator<option<array<BigDecimal.t>>>, @as("exampleBigDecimalArrayRequired") exampleBigDecimalArrayRequired?: Envio.whereOperator<array<BigDecimal.t>>, @as("exampleBigDecimalOtherOrder") exampleBigDecimalOtherOrder?: Envio.whereOperator<BigDecimal.t>}
  }

  module SimpleEntity = {
    type t = {id: id, value: string}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("value") value?: Envio.whereOperator<string>}
  }

  module SimulateTestEvent = {
    type t = {id: id, blockNumber: int, logIndex: int, timestamp: int}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("blockNumber") blockNumber?: Envio.whereOperator<int>, @as("logIndex") logIndex?: Envio.whereOperator<int>, @as("timestamp") timestamp?: Envio.whereOperator<int>}
  }

  module Token = {
    type t = {id: id, tokenId: bigint, collection_id: id, owner_id: id}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("tokenId") tokenId?: Envio.whereOperator<bigint>, @as("collection_id") collection?: Envio.whereOperator<id>, @as("owner_id") owner?: Envio.whereOperator<id>}
  }

  module User = {
    type t = {id: id, address: string, gravatar_id: option<id>, updatesCountOnUserForTesting: int, accountType: Enums.AccountType.t}

    type getWhereFilter = {@as("id") id?: Envio.whereOperator<id>, @as("address") address?: Envio.whereOperator<string>, @as("gravatar_id") gravatar?: Envio.whereOperator<option<id>>, @as("updatesCountOnUserForTesting") updatesCountOnUserForTesting?: Envio.whereOperator<int>, @as("accountType") accountType?: Envio.whereOperator<Enums.AccountType.t>}
  }

  type rec name<'entity> =
    | @as("A") A: name<A.t>
    | @as("B") B: name<B.t>
    | @as("C") C: name<C.t>
    | @as("CustomSelectionTestPass") CustomSelectionTestPass: name<CustomSelectionTestPass.t>
    | @as("D") D: name<D.t>
    | @as("EntityWith63LenghtName______________________________________one") EntityWith63LenghtName______________________________________one: name<EntityWith63LenghtName______________________________________one.t>
    | @as("EntityWith63LenghtName______________________________________two") EntityWith63LenghtName______________________________________two: name<EntityWith63LenghtName______________________________________two.t>
    | @as("EntityWithAllNonArrayTypes") EntityWithAllNonArrayTypes: name<EntityWithAllNonArrayTypes.t>
    | @as("EntityWithAllTypes") EntityWithAllTypes: name<EntityWithAllTypes.t>
    | @as("EntityWithBigDecimal") EntityWithBigDecimal: name<EntityWithBigDecimal.t>
    | @as("EntityWithRestrictedReScriptField") EntityWithRestrictedReScriptField: name<EntityWithRestrictedReScriptField.t>
    | @as("EntityWithTimestamp") EntityWithTimestamp: name<EntityWithTimestamp.t>
    | @as("Gravatar") Gravatar: name<Gravatar.t>
    | @as("NftCollection") NftCollection: name<NftCollection.t>
    | @as("PostgresNumericPrecisionEntityTester") PostgresNumericPrecisionEntityTester: name<PostgresNumericPrecisionEntityTester.t>
    | @as("SimpleEntity") SimpleEntity: name<SimpleEntity.t>
    | @as("SimulateTestEvent") SimulateTestEvent: name<SimulateTestEvent.t>
    | @as("Token") Token: name<Token.t>
    | @as("User") User: name<User.t>
}

type handlerEntityOperations<'entity, 'getWhereFilter> = {
  get: string => promise<option<'entity>>,
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  getWhere: 'getWhereFilter => promise<array<'entity>>,
  getOrCreate: 'entity => promise<'entity>,
  set: 'entity => unit,
  deleteUnsafe: string => unit,
}

type handlerContext = {
  log: Envio.logger,
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
  isPreload: bool,
  chain: Internal.chainInfo,
  \"A": handlerEntityOperations<Entities.A.t, Entities.A.getWhereFilter>,
  \"B": handlerEntityOperations<Entities.B.t, Entities.B.getWhereFilter>,
  \"C": handlerEntityOperations<Entities.C.t, Entities.C.getWhereFilter>,
  \"CustomSelectionTestPass": handlerEntityOperations<Entities.CustomSelectionTestPass.t, Entities.CustomSelectionTestPass.getWhereFilter>,
  \"D": handlerEntityOperations<Entities.D.t, Entities.D.getWhereFilter>,
  \"EntityWith63LenghtName______________________________________one": handlerEntityOperations<Entities.EntityWith63LenghtName______________________________________one.t, Entities.EntityWith63LenghtName______________________________________one.getWhereFilter>,
  \"EntityWith63LenghtName______________________________________two": handlerEntityOperations<Entities.EntityWith63LenghtName______________________________________two.t, Entities.EntityWith63LenghtName______________________________________two.getWhereFilter>,
  \"EntityWithAllNonArrayTypes": handlerEntityOperations<Entities.EntityWithAllNonArrayTypes.t, Entities.EntityWithAllNonArrayTypes.getWhereFilter>,
  \"EntityWithAllTypes": handlerEntityOperations<Entities.EntityWithAllTypes.t, Entities.EntityWithAllTypes.getWhereFilter>,
  \"EntityWithBigDecimal": handlerEntityOperations<Entities.EntityWithBigDecimal.t, Entities.EntityWithBigDecimal.getWhereFilter>,
  \"EntityWithRestrictedReScriptField": handlerEntityOperations<Entities.EntityWithRestrictedReScriptField.t, Entities.EntityWithRestrictedReScriptField.getWhereFilter>,
  \"EntityWithTimestamp": handlerEntityOperations<Entities.EntityWithTimestamp.t, Entities.EntityWithTimestamp.getWhereFilter>,
  \"Gravatar": handlerEntityOperations<Entities.Gravatar.t, Entities.Gravatar.getWhereFilter>,
  \"NftCollection": handlerEntityOperations<Entities.NftCollection.t, Entities.NftCollection.getWhereFilter>,
  \"PostgresNumericPrecisionEntityTester": handlerEntityOperations<Entities.PostgresNumericPrecisionEntityTester.t, Entities.PostgresNumericPrecisionEntityTester.getWhereFilter>,
  \"SimpleEntity": handlerEntityOperations<Entities.SimpleEntity.t, Entities.SimpleEntity.getWhereFilter>,
  \"SimulateTestEvent": handlerEntityOperations<Entities.SimulateTestEvent.t, Entities.SimulateTestEvent.getWhereFilter>,
  \"Token": handlerEntityOperations<Entities.Token.t, Entities.Token.getWhereFilter>,
  \"User": handlerEntityOperations<Entities.User.t, Entities.User.getWhereFilter>,
}

type chainId = [#1337 | #1 | #100 | #137]

type contractRegisterContract = { add: Address.t => unit }

type contractRegisterChain = {
  id: chainId,
  \"EventFiltersTest": contractRegisterContract,
  \"Gravatar": contractRegisterContract,
  \"NftFactory": contractRegisterContract,
  \"Noop": contractRegisterContract,
  \"SimpleNft": contractRegisterContract,
  \"TestEvents": contractRegisterContract,
}

type contractRegisterContext = {
  log: Envio.logger,
  chain: contractRegisterChain,
}

module EventFiltersTest = {
let contractName = "EventFiltersTest"

  module Transfer = {

    let name = "Transfer"
    let contractName = contractName
    type params = {from: Address.t, to: Address.t, amount: bigint}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {from?: Address.t, to?: Address.t, amount?: bigint}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("from") from?: SingleOrMultiple.t<Address.t>, @as("to") to?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the EventFiltersTest contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"EventFiltersTest": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module WildcardWithAddress = {

    let name = "WildcardWithAddress"
    let contractName = contractName
    type params = {from: Address.t, to: Address.t, amount: bigint}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {from?: Address.t, to?: Address.t, amount?: bigint}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("from") from?: SingleOrMultiple.t<Address.t>, @as("to") to?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the EventFiltersTest contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"EventFiltersTest": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module WithExcessField = {

    let name = "WithExcessField"
    let contractName = contractName
    type params = {from: Address.t}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {from?: Address.t}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("from") from?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the EventFiltersTest contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"EventFiltersTest": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module EmptyFiltersArray = {

    let name = "EmptyFiltersArray"
    let contractName = contractName
    type params = {from: Address.t}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {from?: Address.t}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("from") from?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the EventFiltersTest contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"EventFiltersTest": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module FilterTestEvent = {

    let name = "FilterTestEvent"
    let contractName = contractName
    type params = {addr: Address.t}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {addr?: Address.t}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("addr") addr?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the EventFiltersTest contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"EventFiltersTest": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("Transfer") Transfer: eventIdentity<Transfer.event, Transfer.paramsConstructor, Transfer.onEventWhere>
    | @as("WildcardWithAddress") WildcardWithAddress: eventIdentity<WildcardWithAddress.event, WildcardWithAddress.paramsConstructor, WildcardWithAddress.onEventWhere>
    | @as("WithExcessField") WithExcessField: eventIdentity<WithExcessField.event, WithExcessField.paramsConstructor, WithExcessField.onEventWhere>
    | @as("EmptyFiltersArray") EmptyFiltersArray: eventIdentity<EmptyFiltersArray.event, EmptyFiltersArray.paramsConstructor, EmptyFiltersArray.onEventWhere>
    | @as("FilterTestEvent") FilterTestEvent: eventIdentity<FilterTestEvent.event, FilterTestEvent.paramsConstructor, FilterTestEvent.onEventWhere>
}

module Gravatar = {
let contractName = "Gravatar"

  module CustomSelection = {

    let name = "CustomSelection"
    let contractName = contractName
    type params = unit
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = unit
    type block = {
        number: int,
        timestamp: int,
        hash: string,
        parentHash: string,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - nonce")
        nonce?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - sha3Uncles")
        sha3Uncles?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - logsBloom")
        logsBloom?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - transactionsRoot")
        transactionsRoot?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - stateRoot")
        stateRoot?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - receiptsRoot")
        receiptsRoot?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - miner")
        miner?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - difficulty")
        difficulty?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - totalDifficulty")
        totalDifficulty?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - extraData")
        extraData?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - size")
        size?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - gasLimit")
        gasLimit?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - gasUsed")
        gasUsed?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - uncles")
        uncles?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - baseFeePerGas")
        baseFeePerGas?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - blobGasUsed")
        blobGasUsed?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - excessBlobGas")
        excessBlobGas?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - parentBeaconBlockRoot")
        parentBeaconBlockRoot?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - withdrawalsRoot")
        withdrawalsRoot?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - l1BlockNumber")
        l1BlockNumber?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - sendCount")
        sendCount?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - sendRoot")
        sendRoot?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      block_fields:\n        - mixHash")
        mixHash?: unit,
    }
    type transaction = {
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - transactionIndex")
        transactionIndex?: unit,
        hash: string,
        from: option<Address.t>,
        to: option<Address.t>,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - gas")
        gas?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - gasPrice")
        gasPrice?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - maxPriorityFeePerGas")
        maxPriorityFeePerGas?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - maxFeePerGas")
        maxFeePerGas?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - cumulativeGasUsed")
        cumulativeGasUsed?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - effectiveGasPrice")
        effectiveGasPrice?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - gasUsed")
        gasUsed?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - input")
        input?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - nonce")
        nonce?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - value")
        value?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - v")
        v?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - r")
        r?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - s")
        s?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - contractAddress")
        contractAddress?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - logsBloom")
        logsBloom?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - root")
        root?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - status")
        status?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - yParity")
        yParity?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - accessList")
        accessList?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - maxFeePerBlobGas")
        maxFeePerBlobGas?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - blobVersionedHashes")
        blobVersionedHashes?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - type")
        type_?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - l1Fee")
        l1Fee?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - l1GasPrice")
        l1GasPrice?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - l1GasUsed")
        l1GasUsed?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - l1FeeScalar")
        l1FeeScalar?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - gasUsedForL1")
        gasUsedForL1?: unit,
        @deprecated("Not selected for this event. To enable, add to config.yaml:\nevents:\n  - event: CustomSelection\n    field_selection:\n      transaction_fields:\n        - authorizationList")
        authorizationList?: unit,
    }

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module EmptyEvent = {

    let name = "EmptyEvent"
    let contractName = contractName
    type params = unit
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = unit
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module TestEventWithLongNameBeyondThePostgresEnumCharacterLimit = {

    let name = "TestEventWithLongNameBeyondThePostgresEnumCharacterLimit"
    let contractName = contractName
    type params = {testField: Address.t}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {testField?: Address.t}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module TestEventThatCopiesBigIntViaLinkedEntities = {

    let name = "TestEventThatCopiesBigIntViaLinkedEntities"
    let contractName = contractName
    type params = {param_that_should_be_removed_when_issue_1026_is_fixed: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {param_that_should_be_removed_when_issue_1026_is_fixed?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module TestEventWithReservedKeyword = {

    let name = "TestEventWithReservedKeyword"
    let contractName = contractName
    type params = {@as("module") module_: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {@as("module") module_?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module TestEvent = {

    let name = "TestEvent"
    let contractName = contractName
    type params = {id: bigint, user: Address.t, contactDetails: {"name": string, "email": string}}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {id?: bigint, user?: Address.t, contactDetails?: {"0": string, "1": string}}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module TestEventWithCustomName = {

    let name = "TestEventWithCustomName"
    let contractName = contractName
    type params = unit
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = unit
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module NewGravatar = {

    let name = "NewGravatar"
    let contractName = contractName
    type params = {id: bigint, owner: Address.t, displayName: string, imageUrl: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {id?: bigint, owner?: Address.t, displayName?: string, imageUrl?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module UpdatedGravatar = {

    let name = "UpdatedGravatar"
    let contractName = contractName
    type params = {id: bigint, owner: Address.t, displayName: string, imageUrl: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {id?: bigint, owner?: Address.t, displayName?: string, imageUrl?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  module FactoryEvent = {

    let name = "FactoryEvent"
    let contractName = contractName
    type params = {contract: Address.t, testCase: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {contract?: Address.t, testCase?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("contract") contract?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the Gravatar contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"Gravatar": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("CustomSelection") CustomSelection: eventIdentity<CustomSelection.event, CustomSelection.paramsConstructor, CustomSelection.onEventWhere>
    | @as("EmptyEvent") EmptyEvent: eventIdentity<EmptyEvent.event, EmptyEvent.paramsConstructor, EmptyEvent.onEventWhere>
    | @as("TestEventWithLongNameBeyondThePostgresEnumCharacterLimit") TestEventWithLongNameBeyondThePostgresEnumCharacterLimit: eventIdentity<TestEventWithLongNameBeyondThePostgresEnumCharacterLimit.event, TestEventWithLongNameBeyondThePostgresEnumCharacterLimit.paramsConstructor, TestEventWithLongNameBeyondThePostgresEnumCharacterLimit.onEventWhere>
    | @as("TestEventThatCopiesBigIntViaLinkedEntities") TestEventThatCopiesBigIntViaLinkedEntities: eventIdentity<TestEventThatCopiesBigIntViaLinkedEntities.event, TestEventThatCopiesBigIntViaLinkedEntities.paramsConstructor, TestEventThatCopiesBigIntViaLinkedEntities.onEventWhere>
    | @as("TestEventWithReservedKeyword") TestEventWithReservedKeyword: eventIdentity<TestEventWithReservedKeyword.event, TestEventWithReservedKeyword.paramsConstructor, TestEventWithReservedKeyword.onEventWhere>
    | @as("TestEvent") TestEvent: eventIdentity<TestEvent.event, TestEvent.paramsConstructor, TestEvent.onEventWhere>
    | @as("TestEventWithCustomName") TestEventWithCustomName: eventIdentity<TestEventWithCustomName.event, TestEventWithCustomName.paramsConstructor, TestEventWithCustomName.onEventWhere>
    | @as("NewGravatar") NewGravatar: eventIdentity<NewGravatar.event, NewGravatar.paramsConstructor, NewGravatar.onEventWhere>
    | @as("UpdatedGravatar") UpdatedGravatar: eventIdentity<UpdatedGravatar.event, UpdatedGravatar.paramsConstructor, UpdatedGravatar.onEventWhere>
    | @as("FactoryEvent") FactoryEvent: eventIdentity<FactoryEvent.event, FactoryEvent.paramsConstructor, FactoryEvent.onEventWhere>
}

module NftFactory = {
let contractName = "NftFactory"

  module SimpleNftCreated = {

    let name = "SimpleNftCreated"
    let contractName = contractName
    type params = {name: string, symbol: string, maxSupply: bigint, contractAddress: Address.t}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {name?: string, symbol?: string, maxSupply?: bigint, contractAddress?: Address.t}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("SimpleNftCreated") SimpleNftCreated: eventIdentity<SimpleNftCreated.event, SimpleNftCreated.paramsConstructor, SimpleNftCreated.onEventWhere>
}

module Noop = {
let contractName = "Noop"

  module EmptyEvent = {

    let name = "EmptyEvent"
    let contractName = contractName
    type params = unit
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = unit
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {}

    type onEventWhere = Internal.noOnEventWhere
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("EmptyEvent") EmptyEvent: eventIdentity<EmptyEvent.event, EmptyEvent.paramsConstructor, EmptyEvent.onEventWhere>
}

module SimpleNft = {
let contractName = "SimpleNft"

  module Erc20Transfer = {

    let name = "Erc20Transfer"
    let contractName = contractName
    type params = {from: Address.t, to: Address.t, amount: bigint}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {from?: Address.t, to?: Address.t, amount?: bigint}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("from") from?: SingleOrMultiple.t<Address.t>, @as("to") to?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the SimpleNft contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"SimpleNft": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module Transfer = {

    let name = "Transfer"
    let contractName = contractName
    type params = {from: Address.t, to: Address.t, tokenId: bigint}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {from?: Address.t, to?: Address.t, tokenId?: bigint}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("from") from?: SingleOrMultiple.t<Address.t>, @as("to") to?: SingleOrMultiple.t<Address.t>, @as("tokenId") tokenId?: SingleOrMultiple.t<bigint>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the SimpleNft contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"SimpleNft": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("Erc20Transfer") Erc20Transfer: eventIdentity<Erc20Transfer.event, Erc20Transfer.paramsConstructor, Erc20Transfer.onEventWhere>
    | @as("Transfer") Transfer: eventIdentity<Transfer.event, Transfer.paramsConstructor, Transfer.onEventWhere>
}

module TestEvents = {
let contractName = "TestEvents"

  module IndexedUint = {

    let name = "IndexedUint"
    let contractName = contractName
    type params = {num: bigint}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {num?: bigint}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("num") num?: SingleOrMultiple.t<bigint>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedInt = {

    let name = "IndexedInt"
    let contractName = contractName
    type params = {num: bigint}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {num?: bigint}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("num") num?: SingleOrMultiple.t<bigint>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedAddress = {

    let name = "IndexedAddress"
    let contractName = contractName
    type params = {addr: Address.t}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {addr?: Address.t}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("addr") addr?: SingleOrMultiple.t<Address.t>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedBool = {

    let name = "IndexedBool"
    let contractName = contractName
    type params = {isTrue: bool}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {isTrue?: bool}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("isTrue") isTrue?: SingleOrMultiple.t<bool>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedBytes = {

    let name = "IndexedBytes"
    let contractName = contractName
    type params = {dynBytes: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {dynBytes?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("dynBytes") dynBytes?: SingleOrMultiple.t<string>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedString = {

    let name = "IndexedString"
    let contractName = contractName
    type params = {str: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {str?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("str") str?: SingleOrMultiple.t<string>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedFixedBytes = {

    let name = "IndexedFixedBytes"
    let contractName = contractName
    type params = {fixedBytes: string}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {fixedBytes?: string}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("fixedBytes") fixedBytes?: SingleOrMultiple.t<string>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedStruct = {

    let name = "IndexedStruct"
    let contractName = contractName
    type params = {testStruct: {"id": bigint, "name": string}}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {testStruct?: {"0": bigint, "1": string}}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("testStruct") testStruct?: SingleOrMultiple.t<{"0": bigint, "1": string}>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedArray = {

    let name = "IndexedArray"
    let contractName = contractName
    type params = {array: array<bigint>}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {array?: array<bigint>}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("array") array?: SingleOrMultiple.t<array<bigint>>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedFixedArray = {

    let name = "IndexedFixedArray"
    let contractName = contractName
    type params = {array: array<bigint>}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {array?: array<bigint>}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("array") array?: SingleOrMultiple.t<array<bigint>>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedNestedArray = {

    let name = "IndexedNestedArray"
    let contractName = contractName
    type params = {array: array<array<bigint>>}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {array?: array<array<bigint>>}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("array") array?: SingleOrMultiple.t<array<array<bigint>>>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedStructArray = {

    let name = "IndexedStructArray"
    let contractName = contractName
    type params = {array: array<{"id": bigint, "name": string}>}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {array?: array<{"0": bigint, "1": string}>}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("array") array?: SingleOrMultiple.t<array<{"0": bigint, "1": string}>>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedNestedStruct = {

    let name = "IndexedNestedStruct"
    let contractName = contractName
    type params = {nestedStruct: {"id": bigint, "testStruct": {"id": bigint, "name": string}}}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {nestedStruct?: {"0": bigint, "1": {"0": bigint, "1": string}}}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("nestedStruct") nestedStruct?: SingleOrMultiple.t<{"0": bigint, "1": {"0": bigint, "1": string}}>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  module IndexedStructWithArray = {

    let name = "IndexedStructWithArray"
    let contractName = contractName
    type params = {structWithArray: {"numArr": array<bigint>, "strArr": array<string>}}
    /** Event params with all fields optional. Missing fields use default values. */
    type paramsConstructor = {structWithArray?: {"0": array<bigint>, "1": array<string>}}
    type block = Block.t
    type transaction = Transaction.t

    type event = {
      /** The name of the contract that emitted this event. */
      contractName: string,
      /** The name of the event. */
      eventName: string,
      /** The parameters or arguments associated with this event. */
      params: params,
      /** The unique identifier of the blockchain network where this event occurred. */
      chainId: chainId,
      /** The address of the contract that emitted this event. */
      srcAddress: Address.t,
      /** The index of this event's log within the block. */
      logIndex: int,
      /** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
      transaction: transaction,
      /** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
      block: block,
    }

    type whereParams = {@as("structWithArray") structWithArray?: SingleOrMultiple.t<{"0": array<bigint>, "1": array<string>}>}

    type onEventWhereBlockNumber = {_gte?: int}
    type onEventWhereBlock = {number?: onEventWhereBlockNumber}
    type onEventWhereFilter = {params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}
    type onEventWhereChainContract = {/** Addresses of the TestEvents contract on this chain. */ addresses: array<Address.t>}
    type onEventWhereChain = {/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \"TestEvents": onEventWhereChainContract}
    type onEventWhereArgs = {chain: onEventWhereChain}
    @unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll
    type onEventWhere = onEventWhereArgs => onEventWhereResult
  }

  type rec eventIdentity<'event, 'paramsConstructor, 'where> =
    | @as("IndexedUint") IndexedUint: eventIdentity<IndexedUint.event, IndexedUint.paramsConstructor, IndexedUint.onEventWhere>
    | @as("IndexedInt") IndexedInt: eventIdentity<IndexedInt.event, IndexedInt.paramsConstructor, IndexedInt.onEventWhere>
    | @as("IndexedAddress") IndexedAddress: eventIdentity<IndexedAddress.event, IndexedAddress.paramsConstructor, IndexedAddress.onEventWhere>
    | @as("IndexedBool") IndexedBool: eventIdentity<IndexedBool.event, IndexedBool.paramsConstructor, IndexedBool.onEventWhere>
    | @as("IndexedBytes") IndexedBytes: eventIdentity<IndexedBytes.event, IndexedBytes.paramsConstructor, IndexedBytes.onEventWhere>
    | @as("IndexedString") IndexedString: eventIdentity<IndexedString.event, IndexedString.paramsConstructor, IndexedString.onEventWhere>
    | @as("IndexedFixedBytes") IndexedFixedBytes: eventIdentity<IndexedFixedBytes.event, IndexedFixedBytes.paramsConstructor, IndexedFixedBytes.onEventWhere>
    | @as("IndexedStruct") IndexedStruct: eventIdentity<IndexedStruct.event, IndexedStruct.paramsConstructor, IndexedStruct.onEventWhere>
    | @as("IndexedArray") IndexedArray: eventIdentity<IndexedArray.event, IndexedArray.paramsConstructor, IndexedArray.onEventWhere>
    | @as("IndexedFixedArray") IndexedFixedArray: eventIdentity<IndexedFixedArray.event, IndexedFixedArray.paramsConstructor, IndexedFixedArray.onEventWhere>
    | @as("IndexedNestedArray") IndexedNestedArray: eventIdentity<IndexedNestedArray.event, IndexedNestedArray.paramsConstructor, IndexedNestedArray.onEventWhere>
    | @as("IndexedStructArray") IndexedStructArray: eventIdentity<IndexedStructArray.event, IndexedStructArray.paramsConstructor, IndexedStructArray.onEventWhere>
    | @as("IndexedNestedStruct") IndexedNestedStruct: eventIdentity<IndexedNestedStruct.event, IndexedNestedStruct.paramsConstructor, IndexedNestedStruct.onEventWhere>
    | @as("IndexedStructWithArray") IndexedStructWithArray: eventIdentity<IndexedStructWithArray.event, IndexedStructWithArray.paramsConstructor, IndexedStructWithArray.onEventWhere>
}

/** Contract configuration with name and ABI. */
type indexerContract = {
  /** The contract name. */
  name: string,
  /** The contract ABI. */
  abi: unknown,
  /** The contract addresses. */
  addresses: array<Address.t>,
}

/** Per-chain configuration for the indexer. */
type indexerChain = {
  /** The chain ID. */
  id: chainId,
  /** The chain name. */
  name: string,
  /** The block number to start indexing from. */
  startBlock: int,
  /** The block number to stop indexing at (if specified). */
  endBlock: option<int>,
  /** Whether the chain has completed initial sync and is processing live events. */
  isLive: bool,
  \"EventFiltersTest": indexerContract,
  \"Gravatar": indexerContract,
  \"NftFactory": indexerContract,
  \"Noop": indexerContract,
  \"SimpleNft": indexerContract,
  \"TestEvents": indexerContract,
}

/** Strongly-typed record of chain configurations keyed by chain ID. */
type indexerChains = {
  \"1": indexerChain,
  ethereumMainnet: indexerChain,
  \"100": indexerChain,
  gnosis: indexerChain,
  \"137": indexerChain,
  polygon: indexerChain,
  \"1337": indexerChain,
}

@tag("contract")
type eventIdentity<'event, 'paramsConstructor, 'where> =
  | EventFiltersTest(EventFiltersTest.eventIdentity<'event, 'paramsConstructor, 'where>)
  | Gravatar(Gravatar.eventIdentity<'event, 'paramsConstructor, 'where>)
  | NftFactory(NftFactory.eventIdentity<'event, 'paramsConstructor, 'where>)
  | Noop(Noop.eventIdentity<'event, 'paramsConstructor, 'where>)
  | SimpleNft(SimpleNft.eventIdentity<'event, 'paramsConstructor, 'where>)
  | TestEvents(TestEvents.eventIdentity<'event, 'paramsConstructor, 'where>)

@tag("kind")
type simulateItemConstructor<'event, 'paramsConstructor, 'where> =
  | OnEvent({
      event: eventIdentity<'event, 'paramsConstructor, 'where>,
      params?: 'paramsConstructor,
      block?: Internal.evmBlockInput,
      transaction?: Internal.evmTransactionInput,
    })

let makeSimulateItem = (
  constructor: simulateItemConstructor<'event, 'paramsConstructor, 'where>,
): Envio.evmSimulateItem => {
  event: (constructor->Utils.magic)["event"]["_0"],
  contract: (constructor->Utils.magic)["event"]["contract"],
  params: (constructor->Utils.magic)["params"],
  block: (constructor->Utils.magic)["block"],
  transaction: (constructor->Utils.magic)["transaction"],
}

/** Metadata and configuration for the indexer. */
type indexer = {
  /** The name of the indexer from config.yaml. */
  name: string,
  /** The description of the indexer from config.yaml. */
  description: option<string>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
  /** Register an event handler. */
  onEvent: 'event 'paramsConstructor 'where. (
    onEventOptions<eventIdentity<'event, 'paramsConstructor, 'where>, 'where>,
    Internal.genericHandler<Internal.genericHandlerArgs<'event, handlerContext>>,
  ) => unit,
  /** Register a contract register handler for dynamic contract indexing. */
  contractRegister: 'event 'paramsConstructor 'where. (
    onEventOptions<eventIdentity<'event, 'paramsConstructor, 'where>, 'where>,
    Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, contractRegisterContext>>,
  ) => unit,
  /** Register a Block Handler. Evaluates `where` once per configured chain at registration time. */
  onBlock: (
    Envio.onBlockOptions<indexerChain>,
    Envio.evmOnBlockArgs<handlerContext> => promise<unit>,
  ) => unit,
}

/** Get chain configuration by chain ID with exhaustive pattern matching. */
let getChainById = (indexer: indexer, chainId: chainId): indexerChain => {
switch chainId {
  | #1 => indexer.chains.\"1"
  | #100 => indexer.chains.\"100"
  | #137 => indexer.chains.\"137"
  | #1337 => indexer.chains.\"1337"
}
}

type testIndexerProcessConfigChains = {
  \"1"?: TestIndexer.evmChainConfig,
  \"100"?: TestIndexer.evmChainConfig,
  \"137"?: TestIndexer.evmChainConfig,
  \"1337"?: TestIndexer.evmChainConfig,
}

type testIndexerProcessConfig = {
  chains: testIndexerProcessConfigChains,
}

/** Entity operations for direct access outside handlers. */
type testIndexerEntityOperations<'entity> = {
  /** Get an entity by ID. */
  get: string => promise<option<'entity>>,
  /** Get all entities. */
  getAll: unit => promise<array<'entity>>,
  /** Get an entity by ID or throw if not found. */
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  /** Set (create or update) an entity. */
  set: 'entity => unit,
}

/** Test indexer type with process method, entity access, and chain info. */
type testIndexer = {
  /** Process blocks for the specified chains and return progress with changes. */
  process: testIndexerProcessConfig => promise<TestIndexer.processResult>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
  \"A": testIndexerEntityOperations<Entities.A.t>,
  \"B": testIndexerEntityOperations<Entities.B.t>,
  \"C": testIndexerEntityOperations<Entities.C.t>,
  \"CustomSelectionTestPass": testIndexerEntityOperations<Entities.CustomSelectionTestPass.t>,
  \"D": testIndexerEntityOperations<Entities.D.t>,
  \"EntityWith63LenghtName______________________________________one": testIndexerEntityOperations<Entities.EntityWith63LenghtName______________________________________one.t>,
  \"EntityWith63LenghtName______________________________________two": testIndexerEntityOperations<Entities.EntityWith63LenghtName______________________________________two.t>,
  \"EntityWithAllNonArrayTypes": testIndexerEntityOperations<Entities.EntityWithAllNonArrayTypes.t>,
  \"EntityWithAllTypes": testIndexerEntityOperations<Entities.EntityWithAllTypes.t>,
  \"EntityWithBigDecimal": testIndexerEntityOperations<Entities.EntityWithBigDecimal.t>,
  \"EntityWithRestrictedReScriptField": testIndexerEntityOperations<Entities.EntityWithRestrictedReScriptField.t>,
  \"EntityWithTimestamp": testIndexerEntityOperations<Entities.EntityWithTimestamp.t>,
  \"Gravatar": testIndexerEntityOperations<Entities.Gravatar.t>,
  \"NftCollection": testIndexerEntityOperations<Entities.NftCollection.t>,
  \"PostgresNumericPrecisionEntityTester": testIndexerEntityOperations<Entities.PostgresNumericPrecisionEntityTester.t>,
  \"SimpleEntity": testIndexerEntityOperations<Entities.SimpleEntity.t>,
  \"SimulateTestEvent": testIndexerEntityOperations<Entities.SimulateTestEvent.t>,
  \"Token": testIndexerEntityOperations<Entities.Token.t>,
  \"User": testIndexerEntityOperations<Entities.User.t>,
}

@get_index external getTestIndexerEntityOperations: (testIndexer, Entities.name<'entity>) => testIndexerEntityOperations<'entity> = ""

@module("envio") external indexer: indexer = "indexer"

@module("envio") external createTestIndexer: unit => testIndexer = "createTestIndexer"