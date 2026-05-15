// ClickHouse storage writes via Rust + RowBinary.
//
// The Node.js @clickhouse/client only supports text formats for INSERT
// (JSON*, CSV/TSV, Parquet) — no RowBinary or Native. This module gives the
// JS side a napi entry point that POSTs RowBinary directly, skipping both
// the JS-side JSON.stringify and the server-side JSON parse.
//
// Two surfaces:
//   * `clickhouse_insert_checkpoints` — fixed 5-column schema, columnar input.
//   * `clickhouse_insert_rows`        — dynamic schema, row-oriented JSON
//     input (the same JSON values the existing schema compile produces).

use napi::bindgen_prelude::*;
use napi_derive::napi;
use serde_json::Value;
use std::sync::OnceLock;

// ── Wire format primitives (RowBinary) ───────────────────────────────

fn write_leb128(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn write_string(out: &mut Vec<u8>, s: &str) {
    write_leb128(out, s.len() as u64);
    out.extend_from_slice(s.as_bytes());
}

fn write_i32(out: &mut Vec<u8>, v: i32) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn write_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn write_u64(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn write_i64(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn write_f64(out: &mut Vec<u8>, v: f64) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn write_bool(out: &mut Vec<u8>, v: bool) {
    out.push(if v { 1 } else { 0 });
}

// ── Public napi types ────────────────────────────────────────────────

#[napi(object)]
pub struct ClickHouseEndpoint {
    pub url: String,
    pub username: String,
    pub password: String,
    pub database: String,
}

#[napi(string_enum)]
#[derive(Clone, Copy)]
pub enum FieldType {
    Int32,
    UInt32,
    UInt64,
    Float64,
    Bool,
    Str,
    DateTimeMs,
    Enum,
}

#[napi(object)]
pub struct FieldSpec {
    pub name: String,
    pub ty: FieldType,
    pub nullable: bool,
    pub is_array: bool,
    /// Required when `ty == Enum`. Order defines the wire index (0-based).
    pub enum_variants: Option<Vec<String>>,
}

// ── Schema-driven row encoder ────────────────────────────────────────

fn encode_scalar(out: &mut Vec<u8>, v: &Value, spec: &FieldSpec) -> Result<()> {
    macro_rules! type_err {
        ($want:literal) => {
            Error::from_reason(format!(
                "ClickHouse RowBinary: field `{}` expected {}, got {:?}",
                spec.name, $want, v
            ))
        };
    }

    match spec.ty {
        FieldType::Int32 => {
            let n = v.as_i64().ok_or_else(|| type_err!("integer"))?;
            write_i32(out, n as i32);
        }
        FieldType::UInt32 => {
            let n = v.as_u64().ok_or_else(|| type_err!("unsigned integer"))?;
            write_u32(out, n as u32);
        }
        FieldType::UInt64 => {
            // BigInt arrives as a string from JS (rescript-schema serializes
            // BigInt to its decimal string form). Plain numbers are also
            // accepted for ints that fit in JS Number.
            let n = match v {
                Value::String(s) => s.parse::<u64>().map_err(|e| {
                    Error::from_reason(format!(
                        "ClickHouse RowBinary: field `{}` UInt64 parse error: {}",
                        spec.name, e
                    ))
                })?,
                Value::Number(n) => n.as_u64().ok_or_else(|| type_err!("uint64"))?,
                _ => return Err(type_err!("uint64 (string or number)")),
            };
            write_u64(out, n);
        }
        FieldType::Float64 => {
            let n = v.as_f64().ok_or_else(|| type_err!("number"))?;
            write_f64(out, n);
        }
        FieldType::Bool => {
            let b = v.as_bool().ok_or_else(|| type_err!("bool"))?;
            write_bool(out, b);
        }
        FieldType::Str => {
            let s = v.as_str().ok_or_else(|| type_err!("string"))?;
            write_string(out, s);
        }
        FieldType::DateTimeMs => {
            // DateTime64(3) wire = Int64 (ticks at scale=3 → ms since epoch).
            let n = v
                .as_i64()
                .ok_or_else(|| type_err!("datetime ms (number)"))?;
            write_i64(out, n);
        }
        FieldType::Enum => {
            let s = v.as_str().ok_or_else(|| type_err!("enum string"))?;
            let variants = spec.enum_variants.as_ref().ok_or_else(|| {
                Error::from_reason(format!(
                    "ClickHouse RowBinary: enum field `{}` missing variants",
                    spec.name
                ))
            })?;
            let idx = variants.iter().position(|x| x == s).ok_or_else(|| {
                Error::from_reason(format!(
                    "ClickHouse RowBinary: enum field `{}` got unknown variant `{}`",
                    spec.name, s
                ))
            })?;
            // Match the codegen at ClickHouse.res:78-91 — Enum8 up to 127
            // variants, otherwise Enum16.
            if variants.len() <= 127 {
                out.push(idx as u8);
            } else {
                out.extend_from_slice(&(idx as i16).to_le_bytes());
            }
        }
    }
    Ok(())
}

fn encode_value(out: &mut Vec<u8>, v: &Value, spec: &FieldSpec) -> Result<()> {
    if spec.is_array {
        // Note: RowBinary arrays of nullables encode each element with its
        // own 0/1 prefix. We currently flag is_array+nullable as an error
        // upstream rather than handle the combination.
        let arr = match v {
            Value::Array(a) => a,
            _ => {
                return Err(Error::from_reason(format!(
                    "ClickHouse RowBinary: field `{}` expected array",
                    spec.name
                )))
            }
        };
        write_leb128(out, arr.len() as u64);
        let elem_spec = FieldSpec {
            name: spec.name.clone(),
            ty: spec.ty,
            nullable: false,
            is_array: false,
            enum_variants: spec.enum_variants.clone(),
        };
        for elem in arr {
            encode_scalar(out, elem, &elem_spec)?;
        }
        return Ok(());
    }

    if spec.nullable {
        if v.is_null() {
            out.push(1);
            return Ok(());
        }
        out.push(0);
    }
    encode_scalar(out, v, spec)
}

fn encode_rows(schema: &[FieldSpec], rows: &[Value]) -> Result<Vec<u8>> {
    // Heuristic 64 bytes/row; reallocates as needed.
    let mut out = Vec::with_capacity(rows.len() * 64);
    for row in rows {
        let obj = match row {
            Value::Object(o) => o,
            _ => {
                return Err(Error::from_reason(
                    "ClickHouse RowBinary: row is not a JSON object",
                ))
            }
        };
        for spec in schema {
            // Missing fields are treated as null when nullable, error otherwise.
            // Matches what JSONEachRow does on the server.
            let v = obj.get(&spec.name).unwrap_or(&Value::Null);
            encode_value(&mut out, v, spec)?;
        }
    }
    Ok(out)
}

// ── HTTP transport ───────────────────────────────────────────────────

static HTTP: OnceLock<reqwest::Client> = OnceLock::new();

fn http() -> &'static reqwest::Client {
    HTTP.get_or_init(|| {
        reqwest::Client::builder()
            .pool_max_idle_per_host(8)
            .build()
            .expect("reqwest client init")
    })
}

async fn post_row_binary(endpoint: &ClickHouseEndpoint, table: &str, body: Vec<u8>) -> Result<()> {
    let query = format!(
        "INSERT INTO `{}`.`{}` FORMAT RowBinary",
        endpoint.database, table
    );
    let resp = http()
        .post(&endpoint.url)
        .basic_auth(&endpoint.username, Some(&endpoint.password))
        .query(&[("query", query.as_str())])
        .body(body)
        .send()
        .await
        .map_err(|e| Error::from_reason(format!("ClickHouse HTTP send failed: {e}")))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(Error::from_reason(format!(
            "ClickHouse insert failed ({}): {}",
            status, body
        )));
    }
    Ok(())
}

// ── napi entry points ────────────────────────────────────────────────

#[napi]
pub async fn clickhouse_insert_checkpoints(
    endpoint: ClickHouseEndpoint,
    table: String,
    ids: Vec<String>,
    chain_ids: Vec<i32>,
    block_numbers: Vec<i32>,
    block_hashes: Vec<Option<String>>,
    events_processed: Vec<i32>,
) -> Result<()> {
    let n = ids.len();
    if n == 0 {
        return Ok(());
    }
    if chain_ids.len() != n
        || block_numbers.len() != n
        || block_hashes.len() != n
        || events_processed.len() != n
    {
        return Err(Error::from_reason(
            "clickhouse_insert_checkpoints: column lengths mismatch",
        ));
    }

    let mut body = Vec::with_capacity(n * 32);
    for i in 0..n {
        // id: UInt64
        let id = ids[i]
            .parse::<u64>()
            .map_err(|e| Error::from_reason(format!("checkpoint id parse error at {i}: {e}")))?;
        write_u64(&mut body, id);
        // chain_id: Int32
        write_i32(&mut body, chain_ids[i]);
        // block_number: Int32
        write_i32(&mut body, block_numbers[i]);
        // block_hash: Nullable(String)
        match &block_hashes[i] {
            None => body.push(1),
            Some(s) => {
                body.push(0);
                write_string(&mut body, s);
            }
        }
        // events_processed: UInt64
        write_u64(&mut body, events_processed[i] as u64);
    }

    post_row_binary(&endpoint, &table, body).await
}

#[napi]
pub async fn clickhouse_insert_rows(
    endpoint: ClickHouseEndpoint,
    table: String,
    schema: Vec<FieldSpec>,
    rows: Vec<Value>,
) -> Result<()> {
    if rows.is_empty() {
        return Ok(());
    }
    let body = encode_rows(&schema, &rows)?;
    post_row_binary(&endpoint, &table, body).await
}

// ── Tests ────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spec(name: &str, ty: FieldType) -> FieldSpec {
        FieldSpec {
            name: name.to_string(),
            ty,
            nullable: false,
            is_array: false,
            enum_variants: None,
        }
    }

    #[test]
    fn leb128_zero() {
        let mut out = vec![];
        write_leb128(&mut out, 0);
        assert_eq!(out, vec![0]);
    }

    #[test]
    fn leb128_127() {
        let mut out = vec![];
        write_leb128(&mut out, 127);
        assert_eq!(out, vec![127]);
    }

    #[test]
    fn leb128_128() {
        let mut out = vec![];
        write_leb128(&mut out, 128);
        assert_eq!(out, vec![0x80, 0x01]);
    }

    #[test]
    fn leb128_300() {
        let mut out = vec![];
        write_leb128(&mut out, 300);
        assert_eq!(out, vec![0xAC, 0x02]);
    }

    #[test]
    fn string_short() {
        let mut out = vec![];
        write_string(&mut out, "hi");
        assert_eq!(out, vec![2, b'h', b'i']);
    }

    #[test]
    fn nullable_string_present() {
        let schema = vec![FieldSpec {
            name: "x".into(),
            ty: FieldType::Str,
            nullable: true,
            is_array: false,
            enum_variants: None,
        }];
        let rows = vec![json!({"x": "ab"})];
        let body = encode_rows(&schema, &rows).unwrap();
        // 0 (not null) + LEB128(2) + "ab"
        assert_eq!(body, vec![0, 2, b'a', b'b']);
    }

    #[test]
    fn nullable_string_absent() {
        let schema = vec![FieldSpec {
            name: "x".into(),
            ty: FieldType::Str,
            nullable: true,
            is_array: false,
            enum_variants: None,
        }];
        let rows = vec![json!({"x": null})];
        let body = encode_rows(&schema, &rows).unwrap();
        assert_eq!(body, vec![1]);
    }

    #[test]
    fn checkpoints_layout() {
        let schema = vec![
            spec("id", FieldType::UInt64),
            spec("chain_id", FieldType::Int32),
            spec("events_processed", FieldType::UInt64),
        ];
        let rows = vec![json!({
            "id": "1",
            "chain_id": 137,
            "events_processed": "42",
        })];
        let body = encode_rows(&schema, &rows).unwrap();
        let mut want = vec![];
        want.extend_from_slice(&1u64.to_le_bytes());
        want.extend_from_slice(&137i32.to_le_bytes());
        want.extend_from_slice(&42u64.to_le_bytes());
        assert_eq!(body, want);
    }

    #[test]
    fn enum_encodes_index() {
        let schema = vec![FieldSpec {
            name: "envio_change".into(),
            ty: FieldType::Enum,
            nullable: false,
            is_array: false,
            enum_variants: Some(vec!["SET".into(), "DELETE".into()]),
        }];
        let body = encode_rows(&schema, &vec![json!({"envio_change": "DELETE"})]).unwrap();
        assert_eq!(body, vec![1]);
    }

    #[test]
    fn array_of_int32() {
        let schema = vec![FieldSpec {
            name: "xs".into(),
            ty: FieldType::Int32,
            nullable: false,
            is_array: true,
            enum_variants: None,
        }];
        let body = encode_rows(&schema, &vec![json!({"xs": [1, 2, 3]})]).unwrap();
        let mut want = vec![3]; // LEB128(3)
        want.extend_from_slice(&1i32.to_le_bytes());
        want.extend_from_slice(&2i32.to_le_bytes());
        want.extend_from_slice(&3i32.to_le_bytes());
        assert_eq!(body, want);
    }

    #[test]
    fn missing_field_treated_as_null_when_nullable() {
        let schema = vec![FieldSpec {
            name: "maybe".into(),
            ty: FieldType::Str,
            nullable: true,
            is_array: false,
            enum_variants: None,
        }];
        let body = encode_rows(&schema, &vec![json!({})]).unwrap();
        assert_eq!(body, vec![1]);
    }
}
