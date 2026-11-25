
use std::{collections::BTreeMap, ops::Not};

use cookie::Cookie;
use axum::{
    Json, RequestExt, extract::{FromRequest, Multipart, Path, Request}, http::{
        StatusCode, header::{ACCEPT, ACCEPT_LANGUAGE, CONTENT_TYPE, HOST, ORIGIN, REFERER}
    }, response::{IntoResponse, Response}
};
use axum::extract::FromRef;
use bytes::Bytes;
use postgres_types::{to_sql_checked, ToSql};
use serde::{Deserialize, Serialize};
use sqlparser::{ast::{Visit, VisitMut}, dialect::PostgreSqlDialect, parser::Parser};

use crate::{HttpgError, sql::{AllowList, VisitOrderBy}};


#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Eq, Clone)]
pub struct File {
    pub content: Vec<u8>,
    pub content_type: String,
    pub file_name: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq, Clone)]
#[serde(rename_all = "lowercase")]
pub enum Param {
    Text(String),
    Bytea(Vec<u8>),
    Jsonb(serde_json::Value),
    File(File),
}

impl Param {
    pub fn tosql_sync(&self) -> &(dyn ToSql + Sync)
    where
        Self: Sized + Sync
    {
        self
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq, Clone)]
#[serde(rename_all = "lowercase")]
pub enum Type {
    Text,
    Bytea,
    ByteaArray,
    Jsonb,
}

impl From<Param> for Type {
    fn from(def: Param) -> Type {
        match def {
            Param::Text(_) => Type::Text,
            Param::Bytea(_) => Type::Bytea,
            Param::Jsonb(_) => Type::Jsonb,
            Param::File(_) => Type::ByteaArray,
        }
    }
}

impl From<Param> for postgres_types::Type {
    fn from(def: Param) -> postgres_types::Type {
        match def {
            Param::Text(_) => postgres_types::Type::TEXT,
            Param::Bytea(_) => postgres_types::Type::BYTEA,
            Param::File(_) => postgres_types::Type::BYTEA_ARRAY,
            Param::Jsonb(_) => postgres_types::Type::JSONB,
        }
    }
}

impl ToSql for File {
    fn to_sql(&self, ty: &postgres_types::Type, out: &mut bytes::BytesMut) -> Result<postgres_types::IsNull, Box<dyn std::error::Error + Sync + Send>>
    where
        Self: Sized + Sync
    {
            [self.content.to_owned(), self.content_type.to_owned().into(), self.file_name.to_owned().into()].to_sql(ty, out)
    }
    fn accepts(_ty: &postgres_types::Type) -> bool
    where
        Self: Sized {
            true
    }
    to_sql_checked!();
}

impl ToSql for Param {
    fn to_sql(&self, ty: &postgres_types::Type, out: &mut bytes::BytesMut) -> Result<postgres_types::IsNull, Box<dyn std::error::Error + Sync + Send>>
    where
        Self: Sized + Sync,
    {
        match self {
            Param::Text(val) => val.to_sql(ty, out),
            Param::Bytea(val) => val.to_sql(ty, out),
            Param::Jsonb(val) => val.to_sql(ty, out),
            Param::File(val) => val.to_sql(ty, out),
        }
    }
    fn accepts(_ty: &postgres_types::Type) -> bool
    where
        Self: Sized {
            true
    }
    to_sql_checked!();
}

#[derive(Debug, Default, Deserialize, PartialEq, Clone)]
pub struct QueryPart {
    pub sql: Option<String>,
    pub base_path: Option<String>,
    pub params: Option<Vec<serde_json::Value>>,
    pub in_types: Option<Vec<Type>>,
    pub accept: Option<String>,
    pub redirect: Option<String>,
    pub cache_control: Option<String>,
    pub order: Option<BTreeMap<String, serde_json::Value>>,
    pub on_error: Option<String>,
    pub use_primary: Option<String>,
    pub wait_for: Option<String>,
    pub include_lsn: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Clone)]
pub struct Query {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sql: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_path: Option<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub cookies: BTreeMap<String, String>,
    #[serde(skip)]
    pub params: Vec<Param>,
    #[serde(skip)]
    pub files: Vec<File>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub redirect: Option<String>,
    pub scheme: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept_language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_control: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<BTreeMap<String, serde_json::Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_error: Option<String>,
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    pub qs: serde_json::Map<String, serde_json::Value>,
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    pub body: serde_json::Map<String, serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub use_primary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wait_for: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub include_lsn: Option<String>,
}

impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
    crate::AppState: FromRef<S>,
{
    type Rejection = Response;

    async fn from_request(mut req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let headers = req.headers().to_owned();
        let uri = req.uri().to_owned();

        let base_path = req.extract_parts::<Option<Path<String>>>().await.map_err(|e| HttpgError::from(e).into_response()).map(|p| p.map(|p| p.to_string())).ok().flatten();

        let app_state = crate::AppState::from_ref(state);
        let scheme = match app_state.config.tls {
            Some(_) => "https",
            None => "http"
        }.to_string();

        let serde_qs = serde_qs::Config::new()
            .max_depth(5)
            .use_form_encoding(true) // non-strict for browsers
        ;

        let raw_qs = match uri.query() {
            Some(qs) => match serde_qs.deserialize_str::<serde_json::Map<String, serde_json::Value>>(qs) {
                Ok(qs) => Ok(qs),
                Err(e) => {
                    Err((StatusCode::BAD_REQUEST, e.to_string()).into_response())
                }
            }
            None => Ok(serde_json::Map::new()),
        }
        .or(Err(StatusCode::BAD_REQUEST.into_response()))?;

        let content_type_header = headers.get(CONTENT_TYPE);
        let content_type = content_type_header.and_then(|value| value.to_str().ok());

        let (raw_body, files): (serde_json::Map<String, serde_json::Value>, Vec<File>) = match content_type {
            Some(ct) if ct.starts_with("application/json") => {
                (
                    Json::<serde_json::Map<String, serde_json::Value>>::from_request(req, state)
                        .await
                        .or(Err(StatusCode::BAD_REQUEST.into_response()))?.0,
                    vec![]
                )

            },
            Some(ct) if ct.starts_with("application/x-www-form-urlencoded") => {
                (
                    serde_qs.deserialize_bytes::<serde_json::Map<String, serde_json::Value>>(
                        &Bytes::from_request(req, state).await.map_err(|e| HttpgError::from(e).into_response())?
                    )
                    .map_err(|e| HttpgError::from(e).into_response())?,
                    vec![]
                )
            },
            Some(ct) if ct.starts_with("multipart/form-data") => {
                let mut body = serde_json::Map::new();
                let mut files: Vec<File> = vec![];
                let mut multipart = Multipart::from_request(req, state)
                    .await
                    .or(Err(StatusCode::BAD_REQUEST.into_response()))?
                ;

                while let Some(field) = multipart.next_field().await.or(Err(StatusCode::BAD_REQUEST.into_response()))?
                {
                    if field.content_type().is_some() {
                        let file_name = field.file_name().ok_or(StatusCode::BAD_REQUEST.into_response()).map(str::to_string)?;
                        let content_type = field.content_type().ok_or(StatusCode::BAD_REQUEST.into_response()).map(str::to_string)?;
                        let content = field.bytes().await
                            .or(Err(StatusCode::BAD_REQUEST.into_response()))?;
                        files.push(File { content: content.to_vec(), content_type, file_name });
                    } else {
                        body.insert(
                            field.name().ok_or(StatusCode::BAD_REQUEST.into_response()).map(str::to_string)?,
                            serde_json::json!(&field.text().await.or(Err(StatusCode::BAD_REQUEST.into_response()))?)
                        );
                    }
                }
                (body, files)
                
            },
            _ => (serde_json::Map::new(), vec![])
        };

        let qs = serde_json::from_value::<QueryPart>(serde_json::json!(raw_qs)).unwrap_or_default();
        let body = serde_json::from_value::<QueryPart>(serde_json::json!(raw_body)).unwrap_or_default();

        let host = match uri.authority() {
            Some(authority) => Some(authority.as_str()),
            None => headers
                .get(HOST)
                .and_then(|host| host.to_str().ok()),
        };

        let origin = headers.get(ORIGIN).and_then(|value| value.to_str().ok()).map(str::to_string);

        let order = qs.order.to_owned().or(body.order.to_owned());

        let sql = qs.sql.or(body.sql);
        let sql = parse_sql(&order, sql)?;

        let referer_header = headers.get(REFERER);
        let referer = referer_header.and_then(|value| value.to_str().ok());

        let redirect = match qs.redirect.as_ref().or(body.redirect.as_ref()) {
            Some(a) if a == "referer" => referer,
            Some(a) => Some(a.as_str()),
            _ => None,
        };

        let on_error = qs.on_error.to_owned().or(body.on_error.to_owned());
        let on_error = parse_sql(&order, on_error)?;

        let params: Result<Vec<Param>, HttpgError> = qs.params.to_owned()
            .unwrap_or_default()
            .iter()
            .chain(body.params.to_owned()
                .unwrap_or_default()
                .iter()
            )
            .enumerate().map(|(i, param)| {
                let t = match qs.in_types.to_owned().or(body.in_types.to_owned()) {
                    Some(t) => t.get(i).unwrap_or(&Type::Text).to_owned(),
                    None => Type::Text,
                };
                match t {
                    Type::Jsonb => Ok(Param::Jsonb(param.to_owned())),
                    Type::Bytea => Ok(Param::Bytea(
                        serde_json::to_vec(param)
                        .map_err(|_| HttpgError::InvalidParam { i, param: param.to_string() })?
                    )),
                    _ => param.as_str().map(|p| Param::Text(p.to_string())).ok_or_else(|| HttpgError::InvalidParam { i, param: param.to_string() }),
                }
            })
            .collect()
        ;
        let params = [
            params.map_err(|e| e.into_response())?,
            files.to_owned().iter().map(|f| Param::File(f.to_owned())).collect()
        ].concat();

        let accept_language = headers.get(ACCEPT_LANGUAGE).and_then(|value| value.to_str().ok()).map(str::to_string);

        let accept = headers.get(ACCEPT).and_then(|value| value.to_str().ok());
        let accept = qs.accept.to_owned().or(body.accept.to_owned()).or(accept.map(ToString::to_string));

        let cache_control = qs.cache_control.to_owned().or(body.cache_control.to_owned());

        let use_primary = qs.use_primary.or(body.use_primary);
        let wait_for = qs.wait_for.or(body.wait_for);

        Ok(Self {
            sql,
            base_path,
            order,
            cookies: BTreeMap::from_iter(
                headers.get_all("cookie").iter().map(|c| {
                    let c = Cookie::parse(c.to_str()?)?;
                    let (n, v) = c.name_value();
                    Ok((n.to_string(), v.to_string()))
                })
                .collect::<Result<Vec<_>, HttpgError>>()
                .map_err(|e| e.into_response())?
            ),
            params,
            files,
            qs: raw_qs.into_iter().filter_map(|(key, value)|
                ["sql", "on_error", "accept", "content_type", "in_types", "redirect", "cache_control", "order", "use_primary", "wait_for", "include_lsn"]
                    .contains(&key.as_str())
                    .not()
                    .then_some((key, value))
            ).collect(),
            body: raw_body.into_iter().filter_map(|(key, value)|
                ["sql", "on_error", "accept", "content_type", "in_types", "redirect", "cache_control", "order", "use_primary", "wait_for", "include_lsn"]
                    .contains(&key.as_str())
                    .not()
                    .then_some((key, value))
            ).collect(),
            scheme,
            host: host.map(str::to_string),
            origin,
            redirect: redirect.map(str::to_string),
            accept,
            accept_language,
            cache_control,
            on_error,
            use_primary,
            wait_for,
            include_lsn: qs.include_lsn.or(body.include_lsn),
        })
    }
}

fn parse_sql(order: &Option<BTreeMap<String, serde_json::Value>>, root_sql: Option<String>) -> Result<Option<String>, HttpgError> {
    let sql = match &root_sql {
        Some(sql) => match Parser::parse_sql(&PostgreSqlDialect{}, sql.as_str()) {
            Ok(mut statements) => {
                let mut allowlist = AllowList(Err(HttpgError::RefusedSql { query: sql.clone(), reason: None }));
                let _ = Visit::visit(&statements, &mut allowlist);

                if allowlist.0.is_err() {
                    return allowlist.0.map(|_| root_sql.clone());
                }

                if let Some(order) = order.to_owned() {
                    let _ = VisitMut::visit(&mut statements, &mut VisitOrderBy(order));
                    Ok(statements.first().map(|s|s.to_string()))
                }
                else {Ok(Some(sql.to_string()))}
            },
            Err(e) =>
                Err(HttpgError::RefusedSql {query: sql.to_string(), reason: Some(e.to_string())}),
        }?,
        None => None,
    };
    Ok(sql)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
#[allow(clippy::indexing_slicing)]
mod tests {
    use axum::{
        body::Body,
        extract::FromRequest,
        http::{Request, StatusCode, header::{ACCEPT, ACCEPT_LANGUAGE, CONTENT_TYPE, HOST, ORIGIN, REFERER}},
    };
    use conf::Conf;
use http_body_util::BodyExt;
    use serde_json::{Value, json};

    use super::{File, Param, Query, Type, parse_sql};
    use crate::{AppState, HttpgConfig, TlsConfig, error::HttpgError};

    fn test_state() -> AppState {
        let config = HttpgConfig::parse();
        AppState {
            read_pool: config.pg.read_pool().unwrap(),
            write_pool: config.pg.write_pool().unwrap(),
            config,
            listen: None,
        }
    }

    #[tokio::test]
    async fn test_json_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(r#"{"sql":"select 1","params":["b","c"],"accept":"application/json"}"#))
            .unwrap();

        let q = Query::from_request(req, &test_state()).await.unwrap();

        assert_eq!(q.sql.as_deref(), Some("select 1"));
        assert_eq!(q.params, vec![Param::Text("b".into()), Param::Text("c".into())]);
        assert_eq!(q.accept.as_deref(), Some("application/json"));
        assert_eq!(q.scheme, "http");
        assert_eq!(q.body.get("params"), Some(&json!(["b", "c"])));
        assert_eq!(q.body.get("sql"), None);
    }

    #[tokio::test]
    async fn test_urlencoded_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(Body::from("sql=select%201&params[]=b&params[]=c"))
            .unwrap();

        let q = Query::from_request(req, &test_state()).await.unwrap();

        assert_eq!(q.sql.as_deref(), Some("select 1"));
        assert_eq!(q.params, vec![Param::Text("b".into()), Param::Text("c".into())]);
    }

    #[tokio::test]
    async fn test_query_string_order_and_referer_redirect() {
        let req = Request::get(
            "http://example.com/test?sql=select%20id%20from%20things%20as%20t&order%5Bt%5D%5Bid%5D=desc&redirect=referer&foo=bar"
        )
        .header(REFERER, "/back")
        .body(Body::empty())
        .unwrap();

        let q = Query::from_request(req, &test_state()).await.unwrap();

        assert!(q.sql.unwrap_or_default().contains("ORDER BY t.id DESC"));
        assert_eq!(q.redirect.as_deref(), Some("/back"));
        assert_eq!(q.qs.get("foo"), Some(&json!("bar")));
        assert_eq!(q.qs.get("order"), None);
    }

    #[tokio::test]
    async fn test_headers_and_cookies() {
        let req = Request::get("/test")
            .header(HOST, "example.org:3000")
            .header(ORIGIN, "https://example.org")
            .header(ACCEPT, "text/html")
            .header(ACCEPT_LANGUAGE, "fr-FR,fr;q=0.9")
            .header("cookie", "session=abc")
            .header("cookie", "theme=dark")
            .body(Body::empty())
            .unwrap();

        let q = Query::from_request(req, &test_state()).await.unwrap();

        assert_eq!(q.host.as_deref(), Some("example.org:3000"));
        assert_eq!(q.origin.as_deref(), Some("https://example.org"));
        assert_eq!(q.accept.as_deref(), Some("text/html"));
        assert_eq!(q.accept_language.as_deref(), Some("fr-FR,fr;q=0.9"));
        assert_eq!(q.cookies.get("session").map(String::as_str), Some("abc"));
        assert_eq!(q.cookies.get("theme").map(String::as_str), Some("dark"));
    }

    #[tokio::test]
    async fn test_tls_config_uses_https_scheme() {
        let mut state = test_state();
        state.config.tls = Some(TlsConfig {
            pem_file: "localhost.crt".to_string(),
            pem_key_file: "localhost.key".to_string(),
        });

        let req = Request::get("/test").body(Body::empty()).unwrap();
        let q = Query::from_request(req, &state).await.unwrap();

        assert_eq!(q.scheme, "https");
    }

    #[tokio::test]
    async fn test_multipart_body_extracts_files() {
        let body = concat!(
            "--BOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"note\"\r\n",
            "\r\n",
            "hello\r\n",
            "--BOUNDARY\r\n",
            "Content-Disposition: form-data; name=\"upload\"; filename=\"a.txt\"\r\n",
            "Content-Type: text/plain\r\n",
            "\r\n",
            "file content\r\n",
            "--BOUNDARY--\r\n",
        );
        let req = Request::post("/test")
            .header(CONTENT_TYPE, "multipart/form-data; boundary=BOUNDARY")
            .body(Body::from(body))
            .unwrap();

        let q = Query::from_request(req, &test_state()).await.unwrap();

        assert_eq!(q.body.get("note"), Some(&json!("hello")));
        assert_eq!(q.files, vec![File {
            content: b"file content".to_vec(),
            content_type: "text/plain".to_string(),
            file_name: "a.txt".to_string(),
        }]);
        assert_eq!(q.params.last(), Some(&Param::File(q.files[0].clone())));
    }

    #[tokio::test]
    async fn test_invalid_text_param_is_rejected() {
        let req = Request::post("/test")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(r#"{"params":[42]}"#))
            .unwrap();

        let response = Query::from_request(req, &test_state()).await.err().unwrap();
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);

        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert!(String::from_utf8_lossy(&body).contains("invalid param 0"));
    }

    #[tokio::test]
    async fn test_json_body_with_in_types() {
        let req = Request::post("/test")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(r#"{"params":[{"a":1},"raw"],"in_types":["jsonb","bytea"]}"#))
            .unwrap();

        let q = Query::from_request(req, &test_state()).await.unwrap();

        assert_eq!(
            q.params,
            vec![Param::Jsonb(json!({"a": 1})), Param::Bytea(br#""raw""#.to_vec())]
        );
    }

    #[test]
    fn param_serde_uses_lowercase_tags() {
        let cases = [
            (json!({"text": "hello"}), Param::Text("hello".to_string())),
            (json!({"bytea": [1, 2]}), Param::Bytea(vec![1, 2])),
            (json!({"jsonb": {"a": 1}}), Param::Jsonb(json!({"a": 1}))),
        ];
        for (value, param) in cases {
            assert_eq!(serde_json::from_value::<Param>(value.clone()).unwrap(), param);
            assert_eq!(serde_json::to_value(&param).unwrap(), value);
        }
    }

    #[test]
    fn param_maps_to_postgres_types() {
        assert_eq!(Type::from(Param::Text(String::new())), Type::Text);
        assert_eq!(Type::from(Param::Bytea(Vec::new())), Type::Bytea);
        assert_eq!(Type::from(Param::Jsonb(Value::Null)), Type::Jsonb);
        assert_eq!(Type::from(Param::File(File::default())), Type::ByteaArray);

        assert_eq!(postgres_types::Type::from(Param::Text(String::new())), postgres_types::Type::TEXT);
        assert_eq!(postgres_types::Type::from(Param::Bytea(Vec::new())), postgres_types::Type::BYTEA);
        assert_eq!(postgres_types::Type::from(Param::Jsonb(Value::Null)), postgres_types::Type::JSONB);
        assert_eq!(postgres_types::Type::from(Param::File(File::default())), postgres_types::Type::BYTEA_ARRAY);
    }

    #[test]
    fn parse_sql_without_order_keeps_original_spelling() {
        let sql = "select  1";
        assert_eq!(parse_sql(&None, Some(sql.to_string())).unwrap().as_deref(), Some(sql));
    }

    #[test]
    fn parse_sql_without_sql_returns_none() {
        assert_eq!(parse_sql(&None, None).unwrap(), None);
    }

    #[test]
    fn parse_sql_injects_order_by() {
        let order = serde_json::from_value::<std::collections::BTreeMap<String, Value>>(
            json!({"t": {"id": "desc"}}),
        ).unwrap();
        let sql = parse_sql(&Some(order), Some("select id from things as t".to_string()))
            .unwrap()
            .unwrap_or_default();

        assert!(sql.contains("ORDER BY t.id DESC"), "{sql}");
    }

    #[test]
    fn parse_sql_refuses_config_functions_and_non_dml() {
        for sql in ["select current_setting('x')", "create table t (id int)"] {
            let result = parse_sql(&None, Some(sql.to_string()));
            assert!(matches!(result, Err(HttpgError::RefusedSql { .. })), "{sql}: {result:?}");
        }
    }

    #[test]
    fn parse_sql_reports_syntax_errors() {
        let result = parse_sql(&None, Some("select from".to_string()));
        assert!(matches!(
            result,
            Err(HttpgError::RefusedSql { ref reason, .. }) if reason.is_some()
        ));
    }

    #[test]
    fn parse_sql_with_order_keeps_only_the_first_statement() {
        let order = serde_json::from_value::<std::collections::BTreeMap<String, Value>>(
            json!({"t": {"id": "asc"}}),
        ).unwrap();
        let sql = parse_sql(
            &Some(order),
            Some("select id from things as t; select 2".to_string()),
        )
        .unwrap()
        .unwrap_or_default();

        assert!(sql.contains("ORDER BY t.id ASC"), "{sql}");
        assert!(!sql.contains("SELECT 2"), "{sql}");
    }
}

