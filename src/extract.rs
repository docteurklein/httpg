use axum::{
    async_trait, extract::{FromRequest, Request}, http::{header::{CONTENT_TYPE, REFERER}, Method, StatusCode}, response::{IntoResponse, Response}, Json,
};
use bytes::Bytes;
use serde::{Serialize, Deserialize};
use serde_qs::Config;
use std::{borrow::Borrow, collections::BTreeMap};


#[derive(PartialEq, Eq, Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "lowercase")] 
pub enum Order {
    Asc,
    Desc
}

impl From<Order> for bool {
    fn from(f: Order) -> bool {
        match f {
            Order::Asc => true,
            Order::Desc => false,
        }
    }
}

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
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub order: BTreeMap<String, BTreeMap<String, Order>>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_error: Option<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub qs: BTreeMap<String, Param>
}

impl Query {
    fn new(qs: BTreeMap<String, Param>, body: Option<Query>, referer: Option<&str>) -> Self {
        let serde_qs = Config::new(5, false); // non-strict for browsers
        Self {
            sql: match qs.get("sql") {
                Some(Param::String(sql)) => sql.to_string(),
                _ => match &body {
                    Some(Query {sql, ..}) => sql.to_string(),
                    _ => panic!(),
                }
            },
            params: match qs.get("params") {
                Some(Param::Vec(params)) => params.to_vec(),
                _ => match &body {
                    Some(Query {params, ..}) => params.to_vec(),
                    _ => vec![],
                }
            },
            redirect: match qs.get("redirect") {
                Some(Param::String(a)) if a == "referer" => referer.map(str::to_string),
                Some(Param::String(a)) => Some(a.to_string()),
                _ => match &body {
                    Some(Query {redirect: Some(a), ..}) if a == "referer" => referer.map(str::to_string),
                    Some(Query {redirect: Some(a), ..}) => Some(a.to_string()),
                    _ => None,
                }
            },
            order: match qs.get("order") {
                Some(Param::Order(order)) => order.to_owned(),
                _ => match &body {
                    Some(Query {order, ..}) => order.to_owned(),
                    _ => BTreeMap::new(),
                }
            },
            on_error: match qs.get("on_error") {
                Some(Param::String(on_error)) => Some(on_error.to_string()),
                _ => match &body {
                    Some(Query {on_error, ..}) => on_error.to_owned(),
                    _ => None,
                }
            },
            qs,
        }
    }
}

#[derive(PartialEq, Eq, Serialize, Deserialize, Debug, Clone)]
#[serde(untagged)]
pub enum Param {
    String(String),
    Vec(Vec<String>),
    Order(BTreeMap<String, BTreeMap<String, Order>>),
}

#[async_trait]
impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let headers = req.headers().clone();
        let serde_qs = Config::new(5, false); // non-strict for browsers

        let qs = match req.uri().query() {
            Some(qs) => match serde_qs.deserialize_str::<BTreeMap<String, Param>>(qs) {
                Ok(qs) => Ok(Some(qs)),
                Err(e) => {
                    dbg!(&e);
                    Err((StatusCode::BAD_REQUEST, e.to_string()).into_response())
                }
            }
            None => Ok(None),
        };
        let qs = qs.unwrap();

        let content_type_header = headers.get(CONTENT_TYPE);
        let content_type = content_type_header.and_then(|value| value.to_str().ok());

        let body = match content_type {
            Some(ct) if ct.starts_with("application/json") => {
                Ok(Json::<Query>::from_request(req, state)
                    .await
                    .or(Err(StatusCode::BAD_REQUEST.into_response()))?.0
                )
            },
            Some(ct) if ct.starts_with("application/x-www-form-urlencoded") => {
                serde_qs.deserialize_bytes::<Query>(
                    &Bytes::from_request(req, state).await.or(Err(StatusCode::BAD_REQUEST.into_response()))?
                )
                .or(Err(StatusCode::BAD_REQUEST.into_response()))
            },
            _ => Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response())
        };

        let referer_header = headers.get(REFERER);
        let referer = referer_header.and_then(|value| value.to_str().ok());
        
        Ok(Query::new(qs.unwrap_or(BTreeMap::new()), body.ok(), referer))
    }
}

#[cfg(test)]
mod tests {
    use axum::{body::Body, http::{header::CONTENT_TYPE, Request}};

    use axum::extract::FromRequest;
    use crate::extract::Query;
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

