// Shared GraphQL schema backing the per-ecosystem TypeScript API type tests.
// Entities and enums here let each ecosystem's generated context expose the
// same entity operations and schema-bound aliases (Entity/Enum/…).
let schema = `
enum AccountType {
  ADMIN
  USER
}

enum GravatarSize {
  SMALL
  MEDIUM
  LARGE
}

type Account {
  id: ID!
  balance: BigInt!
  accountType: AccountType!
  delegate: Account
}

type Delegation {
  id: ID!
  amount: BigInt!
}
`
