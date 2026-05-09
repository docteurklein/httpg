use std::{pin::Pin, str::FromStr, task::{Context, Poll}};

use axum::{body::Body, http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header::{CACHE_CONTROL, CONTENT_TYPE}}, response::{IntoResponse, Redirect, Response}};
use bytes::{BufMut, Bytes, BytesMut};
use futures::{Stream, stream};
use postgres_types::Type;
use tokio_postgres::{Row, RowStream};

use crate::{HttpgError, extract::query::Query, postgres::QueryGuard};

pub mod compress_stream;

pub struct HttpResult {
    pub query: Query,
    pub rows: CancelStream,
}

pub struct CancelStream {
    inner: Pin<Box<dyn Stream::<Item = Result<Row, tokio_postgres::Error>> + Send>>,
    guard: QueryGuard,
    errored: bool,
}

impl CancelStream {
    pub(crate) fn new(rows: RowStream, guard: QueryGuard) -> Self {
        Self { inner: Box::pin(rows), guard, errored: false }
    }

    pub fn from_vec(vec: Vec<Row>, guard: QueryGuard) -> Self
    {
        
        Self {
            inner: Box::pin(stream::iter(vec.into_iter().map(Ok).collect::<Vec::<_>>())),
            guard,
            errored: false
        }
    }
}

impl Stream for CancelStream {
    type Item = Result<bytes::Bytes, HttpgError>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        if self.errored {
            return Poll::Ready(None);
        }
        let item = self.inner.as_mut().poll_next(cx);
        match item {
            Poll::Ready(Some(Err(e))) => {
                self.errored = true;
                Poll::Ready(Some(Ok(Bytes::from(e.to_string()))))
            },
            Poll::Ready(Some(Ok(row))) => {
                let col = row.columns().first().ok_or(HttpgError::MissingCol)?;
                let val = match col.type_() {
                    &Type::BYTEA => {
                       row.try_get::<usize, Vec<u8>>(0).map(Bytes::from).map_err(HttpgError::from)
                    }
                    &Type::TEXT => {
                       row.try_get::<usize, String>(0).map(Bytes::from).map_err(HttpgError::from)
                    },
                    type_ => Err(HttpgError::InvalidColType {type_: type_.clone()})
                };
                match val {
                    Ok(a) => Poll::Ready(Some(Ok::<_, HttpgError>(a.to_owned()))),
                    Err(e) => {
                        self.errored = true;
                        Poll::Ready(Some(Ok(Bytes::from(e.to_string()))))
                    },
                }
            },
            Poll::Ready(None) => Poll::Ready(None),
            Poll::Pending => Poll::Pending,
        }
    }
}

fn from_col_name(rows: Vec<Row>) -> Result<Response, HttpgError> {
    let mut builder = Response::builder();
    let mut body = BytesMut::new();
    for row in rows.iter() {
        for (i, col) in row.columns().iter().enumerate() {
            match col.name() {
                "status" => {
                    if let Ok(Some(status)) = row.try_get::<usize, Option<i32>>(i) {
                        builder = builder.status(StatusCode::from_u16(status as u16)?);
                    }
                },
                "header" => {
                    if let Ok(Some(name)) = row.try_get::<usize, Option<&str>>(i) {
                        builder = builder.header(HeaderName::from_str(name)?, HeaderValue::from_str(row.try_get(i + 1)?)?);
                    }
                },
                "body" => {
                    if let Some(chunk) = row.try_get::<usize, Option<&[u8]>>(i)? {
                        body.put(chunk);
                    }
                }
                _ => {}
            }
        }
    }
    builder.body(Body::from(body.freeze())).map_err(Into::into)
}

impl IntoResponse for HttpResult {
    fn into_response(self) -> Response {
        if let Some(redirect) = self.query.redirect {
            return Redirect::to(&redirect).into_response();
        }
        let mut headers = HeaderMap::new();

        let accept: Option<HeaderValue> = self.query.accept.and_then(|a| a.parse().ok());
        headers.insert(CONTENT_TYPE, HeaderValue::from_static(match accept {
            Some(a) if a.as_bytes().starts_with(b"text/html") => "text/html; charset=utf-8",
            Some(a) if a.as_bytes().starts_with(b"application/json") => "application/json",
            _ => "application/octet-stream"
        }));

        if let Some(Ok(cache_control)) = self.query.cache_control.map(|a| a.parse()) {
            headers.insert(CACHE_CONTROL, cache_control);
        }

        // let mut builder = Response::builder();

        (headers, Body::from_stream(self.rows)).into_response()
        //.unwrap_or(StatusCode::BAD_REQUEST.into_response())
    }
}

#[cfg(test)]
mod tests {
    use axum::response::IntoResponse;
    use conf::Conf;
    use postgres_types::Type;
    use crate::{extract::query::Query, response::{self, CancelStream}};
    use http_body_util::BodyExt;

    #[tokio::test]
    async fn test_into_response_status() {
        let cfg = crate::postgres::PostgresConfig::parse();
        let conn = cfg.read_pool().unwrap().get().await.unwrap();

        let query = Query {
            sql: "select 'a'::text".into(),
            accept: Some("text/html".to_string()),
            ..Default::default()
        };

        let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
            (param, param.to_owned().into())
        }).collect();

        let rows = conn.query_typed_raw(query.sql.as_ref(), sql_params).await.unwrap();

        let guard = crate::postgres::QueryGuard {
            cancel_token: conn.cancel_token(),
        };

        let rows = CancelStream::new(rows, guard);
        let res = response::HttpResult {
            query: query.clone(),
            rows,
        };

        let body = res.into_response().into_body();

        assert_eq!(body.collect().await.unwrap().to_bytes(), "a\n".to_string().as_bytes());
    }
} 
