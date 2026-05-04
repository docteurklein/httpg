use std::{backtrace::Backtrace, pin::Pin, str::FromStr, task::{Context, Poll}};

use axum::{body::Body, http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header::{CACHE_CONTROL, CONTENT_TYPE}}, response::{Html, IntoResponse, Redirect, Response}};
use bytes::{BufMut, BytesMut};
use futures::Stream;
use tokio_postgres::{Row, RowStream};
use tokio_stream::StreamExt;

use crate::{HttpgError, extract::query::Query, postgres::QueryGuard};

pub mod compress_stream;

pub enum Rows {
    Stream(CancelStream),
    StringVec(Vec<Row>),
    Raw(Vec<Row>),
}

pub struct HttpResult {
    pub query: Query,
    pub rows: Rows,
}

pub struct CancelStream {
    inner: Pin<Box<RowStream>>,
    guard: QueryGuard,
    finished: bool,
}

impl CancelStream {
    pub(crate) fn new(rows: RowStream, guard: QueryGuard) -> Self {
        Self { inner: Box::pin(rows), guard, finished: false }
    }
}

impl Stream for CancelStream {
    type Item = <RowStream as Stream>::Item;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let result = self.inner.as_mut().poll_next(cx);
        match result {
            Poll::Ready(Some(_)) => self.finished = false,
            Poll::Pending => self.finished = false,
            Poll::Ready(None) => self.finished = true,
        }
        result
    }
}

impl Drop for CancelStream {
    fn drop(&mut self) {
        dbg!(&self.finished);
        if !self.finished {
            let cancel_token = self.guard.cancel_token.clone();
            tokio::spawn(async move {
                dbg!("drop");
                let _ = cancel_token.cancel_query(tokio_postgres::NoTls).await;
            });
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
        match self.query.accept {
            Some(a) if a.starts_with("application/json") => {
                match self.rows {
                    Rows::Stream(rows) => {
                        (
                            [("content-type", a)],
                            Body::from_stream(rows.map(|row| {
                                row.and_then(|r| r.try_get::<usize, Option<String>>(0))
                                .map_or_else(
                                    |e| snafu::Report::from_error(
                                        HttpgError::Postgres {source: e, backtrace: Backtrace::capture()}
                                    ).to_string() + "\n",
                                    |v| v.unwrap_or("\n".to_string())
                                )
                            })
                            .map(Ok::<_, HttpgError>)
                            )
                            // .take_while(Result::is_ok))
                        ).into_response()
                    },

                    Rows::StringVec(rows) => Body::from(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_col_name(rows).into_response()
                    }
                }
            },
            Some(a) if a.starts_with("text/html") => {
                match self.rows {
                    Rows::Stream(rows) => {
                        Html(
                            Body::from_stream(rows.map(|row|
                                row
                                    .and_then(|r| r.try_get::<usize, String>(0))
                                    .map_or_else(
                                        |e| snafu::Report::from_error(
                                            HttpgError::Postgres {source: e, backtrace: Backtrace::capture()}
                                        ).to_string() + "\n",
                                        |v| v + "\n"
                                    )
                            // ).take_while(Result::is_ok))
                            )
                            .map(Ok::<_, HttpgError>)
                            )
                        ).into_response()
                    },

                    Rows::StringVec(rows) => Html(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_col_name(rows).into_response()
                    }
                }
            },
            a => {
                match self.rows {
                    Rows::Stream(rows) => {
                        let mut headers = HeaderMap::new();
                        headers.insert(CONTENT_TYPE, a.unwrap_or("application/octet-stream".to_string()).parse().unwrap());
                        if let Some(cache_control) = self.query.cache_control {
                            headers.insert(CACHE_CONTROL, cache_control.parse().unwrap());
                        }

                        (
                            headers,
                            Body::from_stream(rows
                                .map(|row|
                                    row.unwrap().try_get::<usize, Vec<u8>>(0).unwrap_or_else(|e| e.to_string().as_bytes().to_vec())
                                )
                                .map(Ok::<_, axum::Error>)
                            ),
                        ).into_response()
                    },

                    Rows::StringVec(rows) => Body::from(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_col_name(rows).into_response()
                    }
                }
            },
        }
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

        let rows = response::Rows::Stream(CancelStream::new(rows, guard));
        let res = response::HttpResult {
            query: query.clone(),
            rows,
        };

        let body = res.into_response().into_body();

        assert_eq!(body.collect().await.unwrap().to_bytes(), "a\n".to_string().as_bytes());
    }
} 
