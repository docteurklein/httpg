
use axum::{body::Body, http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header::{CACHE_CONTROL, CONTENT_TYPE}}, response::{Html, IntoResponse, Redirect, Response}};
use bytes::{BufMut, Bytes, BytesMut};
use serde::{Deserialize, Serialize};
use tokio_postgres::{Row, RowStream};
use tokio_stream::StreamExt;

use crate::{HttpgError, extract::query::Query};

pub mod compress_stream;

pub enum Rows {
    Stream(RowStream),
    Vec(Vec<Row>),
    Raw(Vec<Raw>),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Raw {
    Status(u16),
    Header(String, String),
    Body(Vec<u8>),
}

pub struct HttpResult {
    pub query: Query,
    pub rows: Rows,
}

fn from_raw(rows: Vec<Raw>) -> Result<Response, HttpgError> {
    let mut builder = Response::builder();
    let mut body = BytesMut::new();
    for row in rows.iter() {
        match row {
            Raw::Status(status) => {
                builder = builder.status(StatusCode::from_u16(status.to_owned())?);
            },
            Raw::Header(k, v) => {
                builder = builder.header(HeaderName::from_bytes(k.as_bytes())?, HeaderValue::from_str(v)?);
            },
            Raw::Body(content) => {
                body.put(content.as_slice());
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

                    Rows::Vec(rows) => Body::from(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_raw(rows).into_response()
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

                    Rows::Vec(rows) => Html(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_raw(rows).into_response()
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

                    Rows::Vec(rows) => Body::from(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_raw(rows).into_response()
                    }
                }
            },
        }
    }
}
  
