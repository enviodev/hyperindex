open LoadCondition

let kindOf = (fieldType: Table.fieldType): valueKind =>
  switch fieldType {
  | String => Text
  | Boolean => Boolean
  | Bytea => Bytes
  | Json => Json
  | Date => Timestamp
  | Enum(_) => Enum
  | Uint32
  | UInt52
  | SmallInt
  | UInt64
  | Int32
  | ChainId
  | Number
  | BigInt(_)
  | BigDecimal(_)
  | Serial
  | BigSerial =>
    Number
  }

@val @scope("JSON") external stringify: unknown => string = "stringify"
%%private(let isDate: unknown => bool = %raw(`(value) => value instanceof Date`))
@send external toISOString: unknown => string = "toISOString"

// A value as its field's schema converts it for storage, spelled as its kind.
let render = (value: unknown, ~kind) =>
  switch value->(Utils.magic: unknown => Nullable.t<unknown>)->Nullable.toOption {
  | None => Null.null
  | Some(value) =>
    Null.make(
      switch kind {
      // A document is its JSON text even when it is a bare string or number.
      | Json => stringify(value)
      | _ =>
        switch value->typeof {
        | #boolean => value->(Utils.magic: unknown => bool) ? "true" : "false"
        | #object =>
          switch value->Utils.Bytes.asUint8Array {
          | Some(bytes) => "0x" ++ bytes->Utils.Bytes.toHex
          | None => isDate(value) ? value->toISOString : String.make(value)
          }
        | _ => String.make(value)
        }
      },
    )
  }

let make = (~filter: EntityFilter.t, ~table: Table.table, ~column: Table.queryField => string) => {
  let getQueryFieldOrThrow = fieldName =>
    switch table->Table.queryFields->Dict.get(fieldName) {
    | Some(queryField) => queryField
    | None =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage. The table doesn't have the field "${fieldName}".`,
          reason: Table.NonExistingTableField(fieldName),
        }),
      )
    }

  let conditions = []
  filter
  ->EntityFilter.entries
  ->Utils.Dict.forEachWithKey((operators, fieldName) => {
    let queryField = getQueryFieldOrThrow(fieldName)
    let kind = kindOf(queryField.fieldType)
    // A value's elements: one for a scalar column, the list's own for a list.
    let elementsOrThrow = fieldValue => {
      let converted = try fieldValue->S.reverseConvertOrThrow(queryField.fieldSchema) catch {
      | exn =>
        throw(
          Persistence.StorageError({
            message: `Failed loading "${table.tableName}" from storage by field "${fieldName}". Couldn't serialize provided value.`,
            reason: exn,
          }),
        )
      }
      queryField.isArray
        ? converted
          ->(Utils.magic: unknown => array<unknown>)
          ->Array.map(element => render(element, ~kind))
        : [render(converted, ~kind)]
    }
    operators->Utils.Dict.forEachWithKey((fieldValue, operator) => {
      let (operator, values) = switch operator {
      | "_eq" => (Eq, [elementsOrThrow(fieldValue)])
      | "_gt" => (Gt, [elementsOrThrow(fieldValue)])
      | "_lt" => (Lt, [elementsOrThrow(fieldValue)])
      | "_gte" => (Gte, [elementsOrThrow(fieldValue)])
      | "_lte" => (Lte, [elementsOrThrow(fieldValue)])
      | "_in" => (In, fieldValue->EntityFilter.asArray->Array.map(elementsOrThrow))
      | _ =>
        throw(
          Persistence.StorageError({
            message: `Failed loading "${table.tableName}" from storage. Unknown filter operator "${operator}".`,
            reason: Utils.Error.make(`Unknown filter operator "${operator}"`),
          }),
        )
      }
      conditions
      ->Array.push({
        column: column(queryField),
        operator,
        values,
        kind,
        isList: queryField.isArray,
        enumName: ?switch queryField.fieldType {
        | Enum({config}) => Some(config.name)
        | _ => None
        },
        isChainId: queryField.isChainId,
      })
      ->ignore
    })
  })
  conditions
}

// The fields and operators a load filtered on, for an error to name.
let describe = (conditions: array<LoadCondition.t>) =>
  conditions
  ->Array.map(condition => `"${condition.column}" ${(condition.operator :> string)}`)
  ->Array.join(", ")
