
use axum::{body::Body, http::{HeaderName, HeaderValue, StatusCode}, response::{Html, IntoResponse, Redirect, Response}};
use bytes::{BufMut, Bytes, BytesMut};
use futures::stream;
use serde::{Deserialize, Serialize};
use tokio_postgres::{Row, RowStream};
use tokio_stream::StreamExt;

use crate::extract::query::Query;

// pub mod compress_stream;

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

pub struct Result {
    pub query: Query,
    pub rows: Rows,
}

fn from_raw(rows: Vec<Raw>) -> Response {
    let mut builder = Response::builder();
    let mut body = BytesMut::new();
    for row in rows.iter() {
        match row {
            Raw::Status(status) => {
                builder = builder.status(StatusCode::from_u16(status.to_owned()).unwrap());
            },
            Raw::Header(k, v) => {
                builder = builder.header(HeaderName::from_bytes(k.as_bytes()).unwrap(), HeaderValue::from_str(v).unwrap());
            },
            Raw::Body(content) => {
                body.put(content.as_slice());
            }
        }
    }
    builder.body(Body::from(body.to_vec())).unwrap()
}

impl IntoResponse for Result {
    fn into_response(self) -> Response {
        if let Some(redirect) = self.query.redirect {
            return Redirect::to(&redirect).into_response();
        }
        match self.query.accept {
            Some(a) if a.starts_with("application/json") => {
                match self.rows {
                    Rows::Stream(rows) =>  (
                        [("content-type",a)],
                        Body::from_stream(rows
                            .map(|row| Bytes::from(row.unwrap().get::<usize, String>(0) + "\n"))
                            .map(Ok::<_, axum::Error>)
                        ),
                    ).into_response(),

                    Rows::Vec(rows) => Body::from(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_raw(rows)
                    }
                }
            },
            Some(a) if a.starts_with("text/html") => {
                match self.rows {
                    Rows::Stream(rows) => Html(
                        Body::from_stream(
                            rows.map(move |row|
                                Bytes::from(row.unwrap().get::<usize, String>(0) + "\n")
                            )
                            .map(Ok::<_, axum::Error>)
                        ).into_response()
                    ).into_response(),

                    Rows::Vec(rows) => Html(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_raw(rows)
                    }
                }
            },
            a => {
                match self.rows {
                    Rows::Stream(rows) => (
                        [("content-type", a.unwrap_or("application/octet-stream".to_string()))],
                        Body::from_stream(rows
                            .map(|row| [row.unwrap().get::<usize, Vec<u8>>(0), "\n".as_bytes().to_vec()].concat())
                            .map(Ok::<_, axum::Error>)
                        ),
                    ).into_response(),

                    Rows::Vec(rows) => Body::from(
                        rows.into_iter().map(|r| r.get(0)).collect::<Vec<String>>().join(" \n")
                    ).into_response(),

                    Rows::Raw(rows) => {
                        from_raw(rows)
                    }
                }
            },
        }
    }
}
  
