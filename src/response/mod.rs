
use std::str::FromStr;

use axum::{body::Body, http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header::{CACHE_CONTROL, CONTENT_TYPE}}, response::{Html, IntoResponse, Redirect, Response}};
use bytes::{BufMut, Bytes, BytesMut};
// use serde::{Deserialize, Serialize};
use tokio_postgres::{Row, RowStream};
use tokio_stream::StreamExt;

use crate::{HttpgError, extract::query::Query};

pub mod compress_stream;

pub enum Rows {
    Stream(RowStream),
    StringVec(Vec<Row>),
    Raw(Vec<Row>),
}

pub struct HttpResult {
    pub query: Query,
    pub rows: Rows,
}

fn from_col_name(rows: Vec<Row>) -> Result<Response, HttpgError> {
    let mut builder = Response::builder();
    let mut body = BytesMut::new();
    for row in rows.iter() {
        for (i, col) in row.columns().iter().enumerate() {
            match col.name() {
                "status" => {
                    builder = builder.status(StatusCode::from_u16(row.get::<usize, u32>(i) as u16)?);
                },
                "header" => {
                    builder = builder.header(HeaderName::from_str(row.get(i))?, HeaderValue::from_str(row.get(i + 1))?);
                },
                "body" => {
                    body.put(row.get::<usize, &[u8]>(i));
                }
                _ => {}
            }
        }
    }
    builder.body(Body::from(body.to_vec())).map_err(Into::into)
}

impl IntoResponse for HttpResult {
    fn into_response(self) -> Response {
        if let Some(redirect) = self.query.redirect {
            return Redirect::to(&redirect).into_response();
        }
        match self.query.accept {
            Some(a) if a.starts_with("application/json") => {
                match self.rows {
                    Rows::Stream(rows) =>  (
                        [("content-type", a)],
                        Body::from_stream(rows
                            .map(|row| Bytes::from(row.unwrap().get::<usize, String>(0) + "\n"))
                            .map(Ok::<_, axum::Error>)
                        ),
                    ).into_response(),

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
                    Rows::Stream(rows) => Html(
                        Body::from_stream(
                            rows.map(|row|
                                row
                                    .and_then(|r| r.try_get::<usize, String>(0))
                                    .map_or_else(|e| HttpgError::Postgres(e).to_string() + "\n", |v| v + "\n")
                            )
                            .map(Ok::<_, HttpgError>)
                        ).into_response()
                    ).into_response(),

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
  
