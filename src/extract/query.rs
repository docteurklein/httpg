use axum::{
    extract::{FromRequest, Request}, http::{header::{ACCEPT, CONTENT_TYPE, REFERER}, StatusCode}, response::{IntoResponse, Response}, Json,
};
use bytes::Bytes;
use serde::{Serialize, Deserialize};
use sqlparser::{ast::VisitMut, dialect::PostgreSqlDialect, parser::Parser};

use crate::sql::VisitOrderBy;


// #[derive(PartialEq, Eq, Serialize, Deserialize, Debug, Clone)]
// #[serde(rename_all = "lowercase")] 
// pub enum Order {
//     Asc,
//     Desc
// }

// impl From<Order> for bool {
//     fn from(f: Order) -> bool {
//         match f {
//             Order::Asc => true,
//             Order::Desc => false,
//         }
//     }
// }

// pub struct Orders(BTreeMap<String, BTreeMap<String, Order>>);

#[derive(Debug, Default, Serialize, Deserialize, PartialEq, Clone)]
pub struct Query {
    pub sql: String,
    #[serde(default)]
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub params: Vec<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub redirect: Option<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accept: Option<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<serde_json::Map<String, serde_json::Value>>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_error: Option<String>,
    // #[serde(default)]
    // #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    // pub qs: BTreeMap<String, Param>,
    // #[serde(default)]
    #[serde(skip_serializing_if = "serde_json::Map::is_empty")]
    pub qs: serde_json::Map<String, serde_json::Value>,
}

impl Query {
    fn new(qs: serde_json::Map<String, serde_json::Value>, body: serde_json::Map<String, serde_json::Value>, referer: Option<&str>, accept: Option<&str>) -> Self {
        let order = match qs.get("order") {
            Some(serde_json::Value::Object(order)) => Some(order.to_owned()),
            _ => match &body.get("order") {
                Some(serde_json::Value::Object(order)) => Some(order.to_owned()),
                _ => None,
            }
        };

        let sql = match qs.get("sql") {
            Some(serde_json::Value::String(sql)) => Some(sql.to_string()),
            _ => match &body.get("sql") {
                Some(serde_json::Value::String(sql)) => Some(sql.to_string()),
                _ => None,
            }
        }.map(|sql| {
            if let Some(order) = order.clone() {
                match Parser::parse_sql(&PostgreSqlDialect{}, &sql) {
                    Ok(mut statements) => {
                        let _ = statements.visit(&mut VisitOrderBy(order));
                        statements[0].to_string()
                    }
                    _ => sql,
                }
            }
            else {sql}
        });

        let redirect = match qs.get("redirect") {
            Some(serde_json::Value::String(a)) if a == "referer" => referer.map(str::to_string),
            Some(serde_json::Value::String(a)) => Some(a.to_string()),
            _ => match &body.get("redirect") {
                Some(serde_json::Value::String(a)) if a == "referer" => referer.map(str::to_string),
                Some(serde_json::Value::String(a)) => Some(a.to_string()),
                _ => None,
            }
        };

        let params = match qs.get("params") {
            Some(serde_json::Value::Array(params)) => params.iter().map(|v| v.as_str().unwrap().to_string()).collect(),
            _ => match &body.get("params") {
                Some(serde_json::Value::Array(params)) => params.iter().map(|v| v.as_str().unwrap().to_string()).collect(),
                _ => vec![],
            }
        };

        Self {
            sql: sql.unwrap(),
            order: order.clone(),
            params,
            redirect,
            accept: accept.map(str::to_string),
            on_error: match qs.get("on_error") {
                Some(serde_json::Value::String(on_error)) => Some(on_error.to_string()),
                _ => match &body.get("on_error") {
                    Some(serde_json::Value::String(on_error)) => Some(on_error.to_string()),
                    _ => None,
                },
            },
            qs,

        }
    }
}

// #[derive(PartialEq, Eq, Serialize, Deserialize, Debug, Clone)]
// #[serde(untagged)]
// pub enum Param {
//     Bigint(i64),
//     String(String),
//     Vec(Vec<Param>),
//     Order(BTreeMap<String, BTreeMap<String, Order>>),
// }

// impl ToSql for Param {
//     fn to_sql(&self, ty: &postgres_types::Type, out: &mut bytes::BytesMut) -> Result<postgres_types::IsNull, Box<dyn std::error::Error + Sync + Send>>
//     where
//         Self: Sized {
//         match self {
//             Param::Bigint(val) => val.to_sql(ty, out),
//             Param::String(val) => val.to_sql(ty, out),
//             Param::Vec(val) => val.to_sql(ty, out),
//             Param::Order(_) => panic!(),
//         }
//     }

//     fn accepts(ty: &postgres_types::Type) -> bool
//     where
//         Self: Sized {
//             <&[i64] as ToSql>::accepts(ty) ||
//             <&[String] as ToSql>::accepts(ty) ||
//             <&[String] as ToSql>::accepts(ty)
//     }

//     to_sql_checked!();
// }

impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let headers = req.headers().clone();
        let serde_qs = serde_qs::Config::new(5, false); // non-strict for browsers

        let qs = match req.uri().query() {
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

        let body = match content_type {
            Some(ct) if ct.starts_with("application/json") => {
                Ok(Json::<serde_json::Map<String, serde_json::Value>>::from_request(req, state)
                    .await
                    .or(Err(StatusCode::BAD_REQUEST.into_response()))?.0
                )
            },
            Some(ct) if ct.starts_with("application/x-www-form-urlencoded") => {
                serde_qs.deserialize_bytes::<serde_json::Map<String, serde_json::Value>>(
                    &Bytes::from_request(req, state).await.or(Err(StatusCode::BAD_REQUEST.into_response()))?
                )
                .or(Err(StatusCode::BAD_REQUEST.into_response()))
            },
            _ => Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response())
        };

        let referer_header = headers.get(REFERER);
        let referer = referer_header.and_then(|value| value.to_str().ok());

        let accept_header = headers.get(ACCEPT);
        let accept = accept_header.and_then(|value| value.to_str().ok());

        Ok(Query::new(qs.unwrap_or_default(), body.ok().unwrap_or_default(), referer, accept))
    }
}

#[cfg(test)]
mod tests {
    use axum::{body::Body, http::{header::CONTENT_TYPE, Request}};

    use axum::extract::FromRequest;
    use crate::extract::query::{Query};
    // use std::collections::HashMap;

    #[tokio::test]
    async fn test_json_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(r#"{"sql": "", "params": ["b"]}"#))
            .unwrap();

        assert_eq!(Query::from_request(req, &()).await.unwrap(), Query {sql: "".to_string(), params: vec!["b".to_string()], ..Default::default()});
    }

    #[tokio::test]
    async fn test_urlencoded_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(Body::from("sql=select%201&params[]=b&params[]=c"))
            .unwrap();

        assert_eq!(Query::from_request(req, &()).await.unwrap(), Query {sql: "select 1".to_string(), params: vec!["b".to_string(), "c".to_string()], ..Default::default()});
    }
}

