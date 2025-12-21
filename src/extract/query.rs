
use std::collections::BTreeMap;

use axum::{
    Json, extract::{FromRequest, Multipart, Request}, http::{
        StatusCode, header::{ACCEPT, ACCEPT_LANGUAGE, CONTENT_TYPE, HOST, REFERER, ORIGIN}
    }, response::{IntoResponse, Response}
};
use bytes::Bytes;
use postgres_types::{to_sql_checked, ToSql};
use serde::{Deserialize, Serialize};
use sqlparser::{ast::VisitMut, dialect::PostgreSqlDialect, parser::Parser};

use crate::{HttpgError, sql::VisitOrderBy};


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

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Clone)]
pub struct QueryPart {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sql: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Vec<serde_json::Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub in_types: Option<Vec<Type>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub redirect: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache_control: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<BTreeMap<String, serde_json::Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub use_primary: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Clone)]
pub struct Query {
    pub sql: String,
    #[serde(skip)]
    pub params: Vec<Param>,
    #[serde(skip)]
    pub files: Vec<File>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub redirect: Option<String>,
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
}

impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let headers = req.headers().to_owned();
        let uri = req.uri().to_owned();
        let serde_qs = serde_qs::Config::new(5, false); // non-strict for browsers

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
                        &Bytes::from_request(req, state).await.or(Err(StatusCode::BAD_REQUEST.into_response()))?
                    )
                    .or(Err(StatusCode::BAD_REQUEST.into_response()))?,
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

        let referer_header = headers.get(REFERER);
        let referer = referer_header.and_then(|value| value.to_str().ok());

        let host = match uri.authority() {
            Some(authority) => Some(authority.as_str()),
            None => headers
                .get(HOST)
                .and_then(|host| host.to_str().ok()),
        };

        let origin = headers.get(ORIGIN).and_then(|value| value.to_str().ok()).map(str::to_string);

        let order = qs.order.to_owned().or(body.order.to_owned());

        let sql = qs.sql.as_ref().or(body.sql.as_ref())
        .map(|sql| {
            if let Some(order) = order.to_owned() {
                match Parser::parse_sql(&PostgreSqlDialect{}, sql) {
                    Ok(mut statements) => {
                        let _ = statements.visit(&mut VisitOrderBy(order));
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

        let on_error = qs.on_error.to_owned().or(body.on_error.to_owned());

        let params: Result<Vec<Param>, Response> = qs.params.to_owned().or(body.params.to_owned()).unwrap_or_default()
            .iter().enumerate().map(|(i, param)| {
                let t = match qs.in_types.to_owned().or(body.in_types.to_owned()) {
                    Some(t) => t.get(i).unwrap_or(&Type::Text).to_owned(),
                    None => Type::Text,
                };
                match t {
                    Type::Jsonb => Ok(Param::Jsonb(param.to_owned())),
                    Type::Bytea => Ok(Param::Bytea(serde_json::to_vec(param).map_err(|_| HttpgError::InvalidTextParam.into_response())?)),
                    _ => Ok(Param::Text(param.as_str().ok_or(HttpgError::InvalidTextParam.into_response())?.to_string())),
                }
            })
            .collect()
        ;
        let params = [
            params?,
            files.to_owned().iter().map(|f| Param::File(f.to_owned())).collect()
        ].concat();

        let accept_language = headers.get(ACCEPT_LANGUAGE).and_then(|value| value.to_str().ok()).map(str::to_string);

        let accept = headers.get(ACCEPT).and_then(|value| value.to_str().ok());
        let accept = qs.accept.to_owned().or(body.accept.to_owned()).or(accept.map(ToString::to_string));

        let cache_control = qs.cache_control.to_owned().or(body.cache_control.to_owned());

        let use_primary = qs.use_primary.or(body.use_primary);

        Ok(Self {
            sql: sql.unwrap_or_default(),
            order,
            params,//: params.or(Err(StatusCode::BAD_REQUEST.into_response()))?,
            files,
            qs: raw_qs,
            body: raw_body,
            host: host.map(str::to_string),
            origin,
            redirect: redirect.map(str::to_string),
            accept,
            accept_language,
            cache_control,
            on_error,
            use_primary,
        })
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

