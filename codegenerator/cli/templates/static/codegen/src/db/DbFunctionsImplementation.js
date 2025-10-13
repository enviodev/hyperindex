const TableModule = require("envio/src/db/Table.res.js");
const { publicSchema } = require("./Db.res.js");

module.exports.batchDeleteItemsInTable = (table, sql, pkArray) => {
  const primaryKeyFieldNames = TableModule.getPrimaryKeyFieldNames(table);

  if (primaryKeyFieldNames.length === 1) {
    return sql`
      DELETE
      FROM ${sql(publicSchema)}.${sql(table.tableName)}
      WHERE ${sql(primaryKeyFieldNames[0])} IN ${sql(pkArray)};
      `;
  } else {
    //TODO, if needed create a delete query for multiple field matches
    //May be best to make pkArray an array of objects with fieldName -> value
  }
};
