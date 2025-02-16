use axum::{
    async_trait, extract::{FromRequest, FromRequestParts, Request}, http::{header::{CONTENT_TYPE, REFERER}, Method, StatusCode}, response::{IntoResponse, Response}, Json,
};
use bytes::Bytes;
use serde::{Serialize, Deserialize};
use serde_qs::Config;
use std::{collections::{BTreeMap, HashMap}, ops::Deref};

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
    pub reorder: BTreeMap<String, String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_error: Option<String>,
}

impl Query {
    fn resolve_referer(&mut self, referer: Option<&str>) -> &mut Self {
        self.redirect = match &self.redirect {
                Some(a) if a == "referer" => referer.map(str::to_string),
                _ => None,
        };
        self
    }
}

#[async_trait]
impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let headers = req.headers().clone();

        let query = match req.method() {
            &Method::GET | &Method::HEAD | &Method::OPTIONS => {
                match req.uri().query() {
                    Some(qs) => Ok(serde_qs::from_str::<Query>(qs).unwrap()),
                    None => Err(StatusCode::BAD_REQUEST.into_response())
                }
            },
            _ => {
                let content_type_header = headers.get(CONTENT_TYPE);
                let content_type = content_type_header.and_then(|value| value.to_str().ok());

                match content_type {
                    Some(ct) if ct.starts_with("application/json") => {
                        Ok(Json::<Query>::from_request(req, state)
                            .await
                            .or(Err(StatusCode::BAD_REQUEST.into_response()))?.0
                        )
                    },
                    Some(ct) if ct.starts_with("application/x-www-form-urlencoded") => {
                        let serde_qs = Config::new(5, false); // non-strict for browsers
                        serde_qs.deserialize_bytes::<Query>(
                            &Bytes::from_request(req, state).await.or(Err(StatusCode::BAD_REQUEST.into_response()))?
                        )
                        .or(Err(StatusCode::BAD_REQUEST.into_response()))
                    },
                    _ => Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response())
                }
            },
        };

        let referer_header = headers.get(REFERER);
        let referer = referer_header.and_then(|value| value.to_str().ok());

        query.map(|mut query| query.resolve_referer(referer).to_owned())
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

