
use std::collections::BTreeMap;

use axum::{
    extract::{FromRequest, Multipart, Request},
    http::{
        header::{ACCEPT, CONTENT_TYPE, REFERER}, StatusCode
    },
    response::{IntoResponse, Response},
    Json,
};
use bytes::Bytes;
use postgres_types::{to_sql_checked, ToSql};
use serde::{Deserialize, Serialize};
use sqlparser::{ast::VisitMut, dialect::PostgreSqlDialect, parser::Parser};

use crate::sql::VisitOrderBy;


#[derive(Debug, Default, PartialEq, Eq, Clone)]
pub struct File {
    pub content: Bytes,
    pub content_type: String,
    pub file_name: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq, Clone)]
#[serde(rename_all = "lowercase")]
pub enum Param {
    Text(String),
    Bytea(Vec<u8>),
    Jsonb(serde_json::Value),
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq, Clone)]
#[serde(rename_all = "lowercase")]
pub enum Type {
    Text,
    Bytea,
    Jsonb,
}

impl From<Param> for Type {
    fn from(def: Param) -> Type {
        match def {
            Param::Text(_) => Type::Text,
            Param::Bytea(_) => Type::Bytea,
            Param::Jsonb(_) => Type::Jsonb,
        }
    }
}

impl From<Param> for postgres_types::Type {
    fn from(def: Param) -> postgres_types::Type {
        match def {
            Param::Text(_) => postgres_types::Type::TEXT,
            Param::Bytea(_) => postgres_types::Type::BYTEA,
            Param::Jsonb(_) => postgres_types::Type::JSONB,
        }
    }
}

impl ToSql for Param {
    fn to_sql(&self, ty: &postgres_types::Type, out: &mut bytes::BytesMut) -> Result<postgres_types::IsNull, Box<dyn std::error::Error + Sync + Send>>
    where
        Self: Sized {
        match self {
            Param::Text(val) => val.to_sql(ty, out),
            Param::Bytea(val) => val.to_sql(ty, out),
            Param::Jsonb(val) => val.to_sql(ty, out),
        }
    }
    fn accepts(_ty: &postgres_types::Type) -> bool
    where
        Self: Sized {
            true
    }
    to_sql_checked!();
}

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Clone)]
pub struct QueryPart {
    pub sql: Option<String>,
    pub params: Option<Vec<serde_json::Value>>,
    pub in_types: Option<Vec<Type>>,
    pub out_types: Option<Vec<Type>>,
    pub content_type: Option<String>,
    pub redirect: Option<String>,
    pub order: Option<BTreeMap<String, serde_json::Value>>,
    pub on_error: Option<String>,
}


#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Clone)]
pub struct Query {
    pub sql: String,
    #[serde(default)]
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub params: Vec<Param>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub redirect: Option<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept: Option<String>,
    pub content_type: Option<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<BTreeMap<String, serde_json::Value>>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_error: Option<String>,
    #[serde(default)]
    pub qs: serde_json::Map<String, serde_json::Value>,
    #[serde(default)]
    pub body: serde_json::Map<String, serde_json::Value>,
    #[serde(skip)]
    pub files: Vec<File>,
    pub out_types: Vec<Type>,
}

impl Query {
    fn new(
        raw_qs: serde_json::Map<String, serde_json::Value>,
        raw_body: serde_json::Map<String, serde_json::Value>,
        files: Vec<File>,
        referer: Option<&str>,
        accept: Option<&str>,
        // out_types: Vec<Type>,
    ) -> Result<Self, Response> {
        let qs = serde_json::from_value::<QueryPart>(serde_json::json!(raw_qs)).unwrap_or_default();
        let body = serde_json::from_value::<QueryPart>(serde_json::json!(raw_body)).unwrap_or_default();

        let order = qs.order.as_ref().or(body.order.as_ref());

        let sql = qs.sql.as_ref().or(body.sql.as_ref())
        .map(|sql| {
            if let Some(order) = order {
                match Parser::parse_sql(&PostgreSqlDialect{}, sql) {
                    Ok(mut statements) => {
                        let _ = statements.visit(&mut VisitOrderBy(order.to_owned()));
                        statements[0].to_string()
                    }
                    _ => sql.to_string(),
                }
            }
            else {sql.to_string()}
        });

        let redirect = match qs.redirect.as_ref().or(body.redirect.as_ref()) {
            Some(a) if a == "referer" => referer,
            Some(a) => Some(a.as_str()),
            _ => None,
        };

        let on_error = qs.on_error.clone().or(body.on_error.clone());

        let params: Vec<Param> = qs.params.clone().or(body.params.clone()).unwrap_or_default().iter().enumerate().map(|(i, param)| {
            let t = match qs.in_types.clone().or(body.in_types.clone()) {
                Some(t) => t.get(i).unwrap_or(&Type::Text).to_owned(),
                None => Type::Text,
            };
            match t {
                Type::Jsonb => Param::Jsonb(param.to_owned()),
                Type::Bytea => Param::Bytea(serde_json::to_vec(param).unwrap()),
                _ => Param::Text(param.as_str().unwrap().to_string()),
            }
        }).collect();

        let content_type = qs.content_type.or(body.content_type);

        let out_types = qs.out_types.or(body.out_types).unwrap_or_default();

        Ok(Self {
            // sql: sql.ok_or((StatusCode::BAD_REQUEST, "missing sql field".to_string()).into_response())?,
            sql: sql.unwrap_or_default(),
            order: order.cloned(),
            params,
            redirect: redirect.map(str::to_string),
            content_type,
            accept: accept.map(str::to_string),
            qs: raw_qs,
            body: raw_body,
            files,
            on_error,
            out_types,
        })
    }

    pub fn accept(self) -> String
    {
        self.content_type.or(self.accept).unwrap_or("application/octet-stream".to_string())
    }
}

impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let headers = req.headers().clone();
        let serde_qs = serde_qs::Config::new(5, false); // non-strict for browsers

        let raw_qs = match req.uri().query() {
            Some(qs) => match serde_qs.deserialize_str::<serde_json::Map<String, serde_json::Value>>(qs) {
                Ok(qs) => Ok(qs),
                Err(e) => {
                    Err((StatusCode::BAD_REQUEST, e.to_string()).into_response())
                }
            }
            None => Ok(serde_json::Map::new()),
        };

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
                        &Bytes::from_request(req, state).await.or(Err(StatusCode::BAD_REQUEST.into_response()))?
                    ).unwrap(),
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

                while let Some(field) = multipart.next_field().await.unwrap() {
                    if field.file_name().is_some() {
                        // let name = field.name().unwrap().to_string();
                        let file_name = field.file_name().unwrap().to_string();
                        let content_type = field.content_type().unwrap().to_string();
                        let content = field.bytes().await.unwrap();
                        files.push(File { content, content_type, file_name });
                    } else {
                        body.insert(field.name().unwrap().to_string(), serde_json::json!(&field.text().await.unwrap()));
                    }

                }
                (body, files)
                
            },
            _ => (serde_json::Map::new(), vec![])
        };

        let referer_header = headers.get(REFERER);
        let referer = referer_header.and_then(|value| value.to_str().ok());

        let accept_header = headers.get(ACCEPT);
        let accept = accept_header.and_then(|value| value.to_str().ok());

        Query::new(raw_qs.unwrap_or_default(), raw_body, files, referer, accept)
    }
}

#[cfg(test)]
mod tests {
    use axum::{body::Body, http::{header::CONTENT_TYPE, Request}};

    use axum::extract::FromRequest;
    use crate::extract::query::{Param, Query};
    // use std::collections::HashMap;

    #[tokio::test]
    async fn test_json_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(r#"{"sql": "", "params": "b"}"#))
            .unwrap();

        assert_eq!(Query::from_request(req, &()).await.unwrap(), Query {sql: "".to_string(), params: vec![Param::Text("b".to_string())], ..Default::default()});
    }

    #[tokio::test]
    async fn test_urlencoded_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(Body::from("sql=select%201&params[]=b&params[]=c"))
            .unwrap();

        assert_eq!(Query::from_request(req, &()).await.unwrap(), Query {sql: "select 1".to_string(), params: vec![Param::Text("b".to_string()), Param::Text("c".to_string())], ..Default::default()});
    }
}

