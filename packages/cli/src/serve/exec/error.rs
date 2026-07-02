//! Hasura-shaped GraphQL errors.
//!
//! Hasura returns HTTP 200 with `{"errors": [{"message", "extensions":
//! {"path", "code"}}]}` for validation errors, and specific shapes/status
//! codes for auth and malformed-request errors. Messages are matched
//! byte-for-byte against the oracle snapshots.

use serde_json::json;

#[derive(Debug, Clone)]
pub struct GraphQLError {
    pub message: String,
    /// JSONPath-ish location, e.g. `$.selectionSet.User.args.limit`.
    pub path: String,
    pub code: &'static str,
    /// HTTP status; Hasura uses 200 for validation errors, 400 for
    /// malformed requests / parse errors / bad json, 401 for auth.
    pub status: u16,
}

pub const CODE_VALIDATION_FAILED: &str = "validation-failed";
pub const CODE_PARSE_FAILED: &str = "parse-failed";
pub const CODE_UNEXPECTED_PAYLOAD: &str = "unexpected-payload";
pub const CODE_ACCESS_DENIED: &str = "access-denied";
pub const CODE_POSTGRES_ERROR: &str = "postgres-error";
pub const CODE_UNEXPECTED: &str = "unexpected";

impl GraphQLError {
    pub fn validation(path: impl Into<String>, message: impl Into<String>) -> GraphQLError {
        GraphQLError {
            message: message.into(),
            path: path.into(),
            code: CODE_VALIDATION_FAILED,
            status: 200,
        }
    }

    #[allow(dead_code)]
    pub fn parse_failed(message: impl Into<String>) -> GraphQLError {
        GraphQLError {
            message: message.into(),
            path: "$.query".to_string(),
            code: CODE_PARSE_FAILED,
            status: 200,
        }
    }

    pub fn unexpected_payload(message: impl Into<String>) -> GraphQLError {
        GraphQLError {
            message: message.into(),
            path: "$".to_string(),
            code: CODE_UNEXPECTED_PAYLOAD,
            status: 200,
        }
    }

    pub fn access_denied() -> GraphQLError {
        GraphQLError {
            message: "invalid x-hasura-admin-secret/x-hasura-access-key".to_string(),
            path: "$".to_string(),
            code: CODE_ACCESS_DENIED,
            status: 401,
        }
    }

    pub fn to_json(&self) -> serde_json::Value {
        json!({
            "message": self.message,
            "extensions": {
                "path": self.path,
                "code": self.code,
            }
        })
    }

    pub fn response_body(&self) -> serde_json::Value {
        json!({ "errors": [self.to_json()] })
    }
}

pub type GResult<T> = Result<T, GraphQLError>;
