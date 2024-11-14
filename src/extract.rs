use axum::{
    async_trait, extract::{FromRequest, Request}, http::{header::CONTENT_TYPE, StatusCode}, response::{IntoResponse, Response}, Json
};
use axum_extra::extract::Form;
use serde::Deserialize;

#[derive(Debug, Default, Deserialize, PartialEq)]
pub struct Query {
    pub query: String,
    #[serde(default)]
    pub params: Vec<String>,
}

#[async_trait]
impl<S> FromRequest<S> for Query
where
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        let content_type_header = req.headers().get(CONTENT_TYPE);
        let content_type = content_type_header.and_then(|value| value.to_str().ok());

        return match content_type {
            Some(ct) if ct.starts_with("application/json") => {
                let Json(query) = Json::<Query>::from_request(req, state)
                    .await
                    .map_err(IntoResponse::into_response)?
                ;
                Ok(query)
            },
            // Some(ct) if ct.starts_with("application/x-www-form-urlencoded") => {
            _ => {
                let Form(query) = Form::<Query>::from_request(req, state)
                    .await
                    .map_err(IntoResponse::into_response)?
                ;
                Ok(query)
            },
            // _ => Err(StatusCode::UNSUPPORTED_MEDIA_TYPE.into_response())
        }
    }
}

#[cfg(test)]
mod tests {
    use axum::{body::Body, http::{header::CONTENT_TYPE, Request}};

    use axum::extract::FromRequest;
    use crate::extract::Query;

    #[tokio::test]
    async fn test_json_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/json")
            .body(Body::from(r#"{"query": "", "params": ["b"]}"#))
            .unwrap();

        assert_eq!(Query::from_request(req, &()).await.unwrap(), Query {query: "".to_string(), params: vec!["b".to_string()]});
    }

    #[tokio::test]
    async fn test_urlencoded_body() {
        let req = Request::post("http://example.com/test")
            .header(CONTENT_TYPE, "application/x-www-form-urlencoded")
            .body(Body::from("query=select%201&params=b"))
            .unwrap();

        assert_eq!(Query::from_request(req, &()).await.unwrap(), Query {query: "select 1".to_string(), params: vec!["b".to_string()]});
    }
}

