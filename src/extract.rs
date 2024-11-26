use anyhow::Error;
use axum::{
    async_trait, extract::{FromRequest, FromRequestParts, RawForm, Request}, http::{header::CONTENT_TYPE, Method, StatusCode}, response::{IntoResponse, Response}, Json,
    RequestPartsExt,
};
use axum_extra::extract::Form;
use bytes::Bytes;
use serde::{Serialize, Deserialize};
use serde_json::Value;
use std::collections::HashMap;

#[derive(Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Query {
    pub sql: String,
    #[serde(default)]
    pub params: Vec<String>,
    #[serde(default)]
    pub redirect: Option<String>,
}

#[async_trait]
impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        match req.method() {
            &Method::GET | &Method::HEAD | &Method::OPTIONS => {
                if let Some(query) = req.uri().query() {
                    Ok(serde_qs::from_str::<Query>(&query).unwrap())
                }
                  else {
                    return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response());
                }
            },
            // Method::POST | Method::PUT | Method::PATCH => {
            _ => {
                let (mut parts, body) = req.into_parts();
                let qs: axum::extract::Query<HashMap<String, String>> = axum::extract::Query::from_request_parts(&mut parts, state)
                    .await
                    .map_err(IntoResponse::into_response)?
                ;
                let req = Request::from_parts(parts, body);

                let content_type_header = req.headers().get(CONTENT_TYPE);
                let content_type = content_type_header.and_then(|value| value.to_str().ok());

                let mut query = match content_type {
                    Some(ct) if ct.starts_with("application/json") => {
                        let Json(query) = Json::<Query>::from_request(req, state)
                            .await
                            .or(Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response()))?
                        ;
                        Ok(query)
                    },
                    Some(ct) if ct.starts_with("application/x-www-form-urlencoded") => {
                    // _ => {
                        Ok(serde_qs::from_bytes::<Query>(&Bytes::from_request(req, state).await.unwrap()).unwrap())
                    },
                    _ => Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response())
                };
                query.as_mut().map(|query| query.redirect = qs.get("redirect").map(|x| x.to_owned())).unwrap();
                query
            },
            // Some(ct) if ct.starts_with("application/x-www-form-urlencoded") => {
            // _ => {
        }
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

