use std::{collections::HashMap, pin::Pin, task::{Context, Poll}};

use axum::{body::Body, http::{HeaderName, HeaderValue, StatusCode, header::{CACHE_CONTROL, CONTENT_TYPE}}, response::{IntoResponse, Redirect, Response}};
use bytes::{Bytes};
use futures::{Stream, StreamExt, stream};
use postgres_types::{Type};
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
        Self {
            inner: Box::pin(rows),
            guard,
            errored: false,
        }
    }

    pub fn from_vec(vec: Vec<Row>, guard: QueryGuard) -> Self
    {
        
        Self {
            inner: Box::pin(stream::iter(vec.into_iter().map(Ok).collect::<Vec::<_>>())),
            guard,
            errored: false,
        }
    }
}

#[derive(Default)]
pub struct RowResult {
    status: Option<u16>,
    header: Option<HashMap<String, Option<String>>>,
    body: Option<bytes::Bytes>,
}

impl Stream for CancelStream {
    type Item = Result<RowResult, HttpgError>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        if self.errored {
            return Poll::Ready(None);
        }
        let item = self.inner.as_mut().poll_next(cx);
        match item {
            Poll::Ready(Some(Err(e))) => {
                self.errored = true;
                Poll::Ready(Some(Ok(RowResult {
                    body: Some(Bytes::from(e.to_string())),
                    ..Default::default()
                })))
            },
            Poll::Ready(Some(Ok(row))) => {

                let mut res = RowResult::default();
                for (i, col) in row.columns().iter().enumerate() {
                    match col.name() {
                        "status" => {
                            if let Ok(Some(status)) = row.try_get::<usize, Option<i32>>(i) {
                                res.status = Some(status as u16);
                            }
                        },
                        "header" => {
                            if let Ok(h) = row.try_get::<usize, Option<HashMap<String, Option<String>>>>(i) {
                                res.header = h;
                            }
                        },
                        _ => { // body
                            match col.type_() {
                                &Type::BYTEA => {
                                    if let Ok(Some(b)) = row.try_get::<usize, Option<&[u8]>>(i) {
                                        res.body = Some(bytes::Bytes::from(b.to_owned()));
                                    }
                                }
                                &Type::TEXT => {
                                    if let Ok(Some(b)) = row.try_get::<usize, Option<&str>>(i) {
                                        res.body = Some(bytes::Bytes::from(b.to_owned()));
                                    }
                                },
                                // &Type::REFCURSOR => {
                                // },
                                type_ => {
                                    self.errored = true;
                                    res.body = Some(Bytes::from(
                                        HttpgError::InvalidColType {type_: type_.clone()}.to_string()
                                    ));
                                }
                            };
                        }
                    };
                };
                Poll::Ready(Some(Ok(res)))
            },
            Poll::Ready(None) => {
                self.guard.finished = true;
                Poll::Ready(None)
            },
            Poll::Pending => Poll::Pending,
        }
    }
}

impl IntoResponse for HttpResult {
    fn into_response(self) -> Response {
        if let Some(redirect) = self.query.redirect {
            return Redirect::to(&redirect).into_response();
        }
        let mut builder = Response::builder();
        let headers = builder.headers_mut().unwrap();

        let accept: Option<HeaderValue> = self.query.accept.and_then(|a| a.parse().ok());
        headers.insert(CONTENT_TYPE, match accept {
            Some(a) if a.as_bytes().starts_with(b"text/html") => HeaderValue::from_static("text/html; charset=utf-8"),
            Some(a) if a.as_bytes().starts_with(b"application/json") => HeaderValue::from_static("application/json"),
            Some(a) => a,
            _ => HeaderValue::from_static("application/octet-stream"),
        });

        if let Some(Ok(cache_control)) = self.query.cache_control.map(|a| a.parse::<HeaderValue>()) {
            headers.insert(CACHE_CONTROL, cache_control);
        }

        // headers.insert("X-Accel-Buffering".parse::<HeaderName>().unwrap(), "no".parse::<HeaderValue>().unwrap());

        let mut iter = futures::executor::block_on_stream(self.rows);

        let mut b = vec![];
        let mut n = iter.next();
        while let Some(Ok(a)) = n {
            if let Some(s) = a.status {
                builder = builder.status(s);
            }
            if let Some(h) = a.header {
                for (k, v) in h.into_iter() {
                    if let (Ok(k), Some(Ok(v))) = (HeaderName::from_bytes(k.as_bytes()), v.as_ref().map(String::as_bytes).map(HeaderValue::from_bytes)) {
                        builder = builder.header(k, v);
                    }
                }
            }
            if a.body.is_some() {
                b.push(Ok(RowResult {
                    body: a.body,
                    ..Default::default()
                }));
                n = None;
            }
            else {
                n = iter.next();
            }
        }

        let stream = futures::stream::iter(b).chain(iter.into_inner());

        builder
            .body(Body::from_stream(stream.map(|r| r.map(|r| r.body.unwrap_or_default()))))
            .unwrap_or(StatusCode::BAD_REQUEST.into_response())
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
            finished: false,
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
