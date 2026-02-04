use axum::{extract::multipart, http::{self, header}, response::{IntoResponse, Response}};
use biscuit_auth::error;
use deadpool_postgres::{CreatePoolError, PoolError};
use http::StatusCode;
use lettre::{address, transport};

#[derive(Debug, snafu::Snafu)]
#[snafu(visibility(pub(crate)))]
pub enum HttpgError {
    #[snafu(transparent)]
    Io {
        source: std::io::Error,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Conf {
        source: conf::Error,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Postgres {
        source: tokio_postgres::Error,
        backtrace: std::backtrace::Backtrace,
    },
    #[snafu(transparent)]
    Deadpool {
        source: PoolError,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    DeadpoolConfig {
        source: CreatePoolError,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    BiscuitToken {
        source: error::Token,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    BiscuitFormat {
        source: error::Format,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Serde {
        source: serde_json::Error,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Axum {
        source: http::Error,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    AxumHeaderName {
        source: header::InvalidHeaderName,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    AxumHeaderValue {
        source: header::InvalidHeaderValue,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    AxumCode {
        source: http::status::InvalidStatusCode,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    AxumMultipart {
        source: multipart::MultipartError,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Email {
        source: lettre::error::Error,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    EmailAddress {
        source: address::AddressError,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Smtp {
        source: transport::smtp::Error,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    HttpClient {
        source: reqwest::Error,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Hex {
        source: hex::FromHexError,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    WebPush {
        source: web_push::WebPushError,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    Uri {
        source: http::uri::InvalidUri,
        backtrace: snafu::Backtrace,
    },
    #[snafu(transparent)]
    QueryString {
        source: serde_qs::Error,
        backtrace: snafu::Backtrace,
    },
    WebPushPrivateKey,
    InvalidTextParam,
}

impl IntoResponse for HttpgError {
    fn into_response(self) -> Response {
        tracing::error!("{self:#?}");
        if let Some(b) = snafu::ErrorCompat::backtrace(&self) {
            dbg!(&b);
        }

        (StatusCode::INTERNAL_SERVER_ERROR, self.to_string()).into_response()
    }
}

