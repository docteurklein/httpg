use axum::{extract::multipart, http::{self, header}, response::{IntoResponse, Response}};
use biscuit_auth::error;
use deadpool_postgres::{CreatePoolError, PoolError};
use http::StatusCode;
use lettre::{address, transport};

#[derive(thiserror::Error, Debug)]
pub enum HttpgError {
    #[error("io: {0:#?}")]
    Io(#[from] std::io::Error),
    #[error("config: {0:#?}")]
    Config(#[from] config::ConfigError),
    #[error("postgres: {0:#?}")]
    Postgres(#[from] tokio_postgres::Error),
    #[error("deadpool: {0:#?}")]
    Deadpool(#[from] PoolError),
    #[error("deadpool config: {0:#?}")]
    DeadpoolConfig(#[from] CreatePoolError),
    #[error("biscuit token: {0:#?}")]
    BiscuitToken(#[from] error::Token),
    #[error("biscuit format: {0:#?}")]
    BiscuitFormat(#[from] error::Format),
    #[error("serde: {0:#?}")]
    Serde(#[from] serde_json::Error),
    #[error("axum: {0:#?}")]
    Axum(#[from] http::Error),
    #[error("axum header name: {0:#?}")]
    AxumHeaderName(#[from] header::InvalidHeaderName),
    #[error("axum header value: {0:#?}")]
    AxumHeaderValue(#[from] header::InvalidHeaderValue),
    #[error("axum code: {0:#?}")]
    AxumCode(#[from] http::status::InvalidStatusCode),
    #[error("axum multipart: {0:#?}")]
    AxumMultipart(#[from] multipart::MultipartError),
    #[error("email: {0:#?}")]
    Email(#[from] lettre::error::Error),
    #[error("email: {0:#?}")]
    EmailAddress(#[from] address::AddressError),
    #[error("email: {0:#?}")]
    Smtp(#[from] transport::smtp::Error),
    #[error("http: {0:#?}")]
    HttpClient(#[from] reqwest::Error),
    #[error("hex: {0:#?}")]
    Hex(#[from] hex::FromHexError),
    #[error("web_push: {0:#?}")]
    WebPush(#[from] web_push::WebPushError),
    #[error("uri: {0:#?}")]
    Uri(#[from] http::uri::InvalidUri),
    #[error("querystring: {0:#?}")]
    QueryString(#[from] serde_qs::Error),
    #[error("no webpush private key")]
    WebPushPrivateKey,
    #[error("invalid text param")]
    InvalidTextParam,
}

impl IntoResponse for HttpgError {
    fn into_response(self) -> Response {
        tracing::error!("{self:#?}");
        (StatusCode::INTERNAL_SERVER_ERROR, self.to_string()).into_response()
    }
}

