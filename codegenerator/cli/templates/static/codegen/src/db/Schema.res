open Belt
type t = dict<Table.table>

let make = (tables: array<Table.table>) => {
  tables->Array.map(table => (table.tableName, table))->Js.Dict.fromArray
}

exception UndefinedEntity(Table.derivedFromField)
exception UndefinedFieldInEntity(Table.derivedFromField)
let getDerivedFromFieldName = (schema: t, derivedFromField: Table.derivedFromField) =>
  switch schema->Utils.Dict.dangerouslyGetNonOption(derivedFromField.derivedFromEntity) {
  | Some(entity) =>
    switch entity->Table.getFieldByName(derivedFromField.derivedFromField) {
    | Some(field) => field->Table.getFieldName->Ok
    | None => Error(UndefinedFieldInEntity(derivedFromField)) //Unexpected, schema should be parsed on codegen
    }
  | None => Error(UndefinedEntity(derivedFromField)) //Unexpected, schema should be parsed on codegen
  }
