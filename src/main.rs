use axum::{
    Router, extract::{DefaultBodyLimit, State}, http::{
        StatusCode, header::SET_COOKIE,
    }, response::{Html, IntoResponse, NoContent, Redirect, Response}, routing::{get, post}
};
use axum_extra::extract::cookie::Cookie;
use axum_server::tls_rustls::RustlsConfig;
use axum_macros::debug_handler;
use conf::Conf;

use config::ConfigError;
use futures::{TryStreamExt};
use lettre::{
    message::header::ContentType, transport::smtp::authentication::Credentials, AsyncSmtpTransport,
    AsyncTransport, Message, Tokio1Executor,
};
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio_postgres_rustls::MakeRustlsConnect;
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir};
use core::{panic};
use std::{fs, net::TcpListener, sync::Arc};
use std::env;
use std::net::SocketAddr;
use tokio_postgres::{IsolationLevel, NoTls};
use tokio_postgres::types::{ToSql, Type};
use deadpool_postgres::{CreatePoolError, Pool, PoolError, Runtime, Transaction};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use biscuit_auth::{KeyPair, PrivateKey, Biscuit, builder::*};

use crate::{extract::query::{Query}, response::Raw};
// use crate::response::compress_stream;

mod extract;
mod sql;
mod response;

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
    BiscuitToken(#[from] biscuit_auth::error::Token),
    #[error("biscuit format: {0:#?}")]
    BiscuitFormat(#[from] biscuit_auth::error::Format),
    #[error("serde: {0:#?}")]
    Serde(#[from] serde_json::Error),
    #[error("axum: {0:#?}")]
    Axum(#[from] axum::http::Error),
    #[error("axum header name: {0:#?}")]
    AxumHeaderName(#[from] axum::http::header::InvalidHeaderName),
    #[error("axum header value: {0:#?}")]
    AxumHeaderValue(#[from] axum::http::header::InvalidHeaderValue),
    #[error("axum code: {0:#?}")]
    AxumCode(#[from] axum::http::status::InvalidStatusCode),
    #[error("axum multipart: {0:#?}")]
    AxumMultipart(#[from] axum::extract::multipart::MultipartError),
    #[error("email: {0:#?}")]
    Email(#[from] lettre::error::Error),
    #[error("email: {0:#?}")]
    EmailAddress(#[from] lettre::address::AddressError),
    #[error("email: {0:#?}")]
    Smtp(#[from] lettre::transport::smtp::Error),
    #[error("invalid text param")]
    InvalidTextParam,
}

impl IntoResponse for HttpgError {
    fn into_response(self) -> Response {
        (StatusCode::INTERNAL_SERVER_ERROR, self.to_string()).into_response()
    }
}


#[derive(Clone, Debug, Deserialize, Serialize)]
struct DeadPoolConfig {
    #[serde(default)]
    pg: deadpool_postgres::Config,
}

impl DeadPoolConfig {
    pub fn read() -> Result<Self, config::ConfigError> {
        let config = config::Config::builder()
            .add_source(config::Environment::default()
                .prefix("PG")
                .separator("_")
                .keep_prefix(true)
            )
            .add_source(config::Environment::default()
                .prefix("PG_READ")
                .separator("_")
                .keep_prefix(false)
            )
            .build()?
        ;

        config.try_deserialize::<Self>()
    }

    pub fn write() -> Result<Self, config::ConfigError> {
        let config = config::Config::builder()
            .add_source(config::Environment::default()
                .prefix("PG")
                .separator("_")
                .keep_prefix(true)
            )
            .add_source(config::Environment::default()
                .prefix("PG_WRITE")
                .separator("_")
                .keep_prefix(false)
            )
            .build()?
        ;

        config.try_deserialize::<Self>()
    }
}

#[derive(Clone, Conf)]
struct TlsConfig {
    #[conf(env, value_parser = |file: &str| -> Result<_, Box<dyn std::error::Error>> { Ok(fs::read_to_string(file)?) })]
    pem: String,
    #[conf(env, value_parser = |file: &str| -> Result<_, Box<dyn std::error::Error>> { Ok(fs::read_to_string(file)?) })]
    pem_key: String,
}

#[derive(Clone, Conf)]
#[conf(env_prefix="HTTPG_")]
struct HttpgConfig {
    #[conf(env, value_parser = |file: &str| -> Result<_, Box<dyn std::error::Error>> { Ok(hex::decode(fs::read_to_string(file)?)?) })]
    private_key: Vec<u8>,
    #[conf(env)]
    smtp_sender: String,
    #[conf(env)]
    smtp_user: String,
    #[conf(env)]
    smtp_password: String,
    #[conf(env)]
    smtp_relay: String,
    #[conf(env)]
    anon_role: String,
    #[conf(env)]
    index_sql: String,
    #[conf(env)]
    login_query: String,
    #[conf(env, default_value="3000")]
    port: u16,
    #[conf(flatten)]
    tls: Option<TlsConfig>,
}

impl HttpgConfig {
    pub fn from_env() -> Result<Self, ConfigError> {
        // let port = env::var("PORT").unwrap_or("3000".to_string());
        // let config = config::Config::builder()
        //     .add_source(
        //         config::Environment::default()
        //         .source(Some(HashMap::from([("port".to_string(), port.to_string())])))
        //     )
        //     .add_source(config::Environment::default()
        //         .prefix("HTTPG")
        //     )
        //     .build()
        //     .unwrap()
        // ;

        Ok(HttpgConfig::parse())
    }
}

#[derive(Clone)]
struct AppState {
    read_pool: Pool,
    write_pool: Pool,
    config: HttpgConfig,
}

#[tokio::main]
async fn main() -> Result<(), HttpgError> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            env::var("RUST_LOG").unwrap_or("httpg=debug".to_string()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();


    let httpg_config = HttpgConfig::from_env()?;

    let read_pool = create_pool(DeadPoolConfig::read()?, env::var("PG_SSLMODE").is_ok())?;
    let write_pool = create_pool(DeadPoolConfig::write()?, env::var("PG_SSLMODE").is_ok())?;
    
    let state = AppState {
        read_pool,
        write_pool,
        config: httpg_config.to_owned(),
    };

    let cors = CorsLayer::new()
        .allow_origin(Any);

    let app = Router::new()
        .route("/", get(index))
        .route("/login", get(login).post(login))
        .route("/query", get(stream_query).post(post_query))
        .route("/raw", get(raw_http).post(raw_http))
        .route("/email", post(email))
        .fallback_service(ServeDir::new("public"))
        .with_state(state)
        .layer(DefaultBodyLimit::disable()) //max(1024 * 100))
        // .layer(axum::middleware::from_fn(compress_stream::compress_stream)) //nope with stream
        .layer(ServiceBuilder::new().layer(cors))
    ;

    let addr = SocketAddr::from((
        [0, 0, 0, 0],
        httpg_config.port,
    ));
    let tcp = TcpListener::bind(addr)?;
    tracing::debug!("listening on {}", tcp.local_addr()?);

    
    match httpg_config.tls {
        Some(tls) =>  {
            let config = RustlsConfig::from_pem_file(
                tls.pem,
                tls.pem_key,
            )
            .await;

            axum_server::from_tcp_rustls(tcp, config?)
                .serve(app.into_make_service())
                .await?
        },
        None => {
            axum_server::from_tcp(tcp)
                .serve(app.into_make_service())
                .await?
        },
    };
    Ok(())
}

fn create_pool(cfg: DeadPoolConfig, is_ssl: bool) -> Result<Pool, HttpgError> {
    if is_ssl {
        let tls_config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
            .with_no_client_auth()
        ;
        let tls = MakeRustlsConnect::new(tls_config);

        cfg.pg.create_pool(Some(Runtime::Tokio1), tls).map_err(Into::into)
    }
    else {
        cfg.pg.create_pool(Some(Runtime::Tokio1), NoTls).map_err(Into::into)
    }
}

#[debug_handler]
async fn index(
    state: State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    mut query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {

    query.sql = state.config.index_sql.to_owned();

    stream_query(state.clone(), biscuit, query).await
}

#[debug_handler]
async fn login(
    State(AppState {write_pool, config: HttpgConfig { login_query, anon_role, private_key, ..}, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {
    let root = KeyPair::from(&PrivateKey::from_bytes(&private_key)?);

    let mut conn = write_pool.get().await?;
    let mut tx = conn.build_transaction()
        .isolation_level(IsolationLevel::Serializable)
        .start().await?
    ;

    pre(&mut tx, &biscuit, &anon_role, &query).await?;

    let params: [&(dyn ToSql + Sync); 0] = [];
    let facts = tx.query(&login_query, &params).await?;

    let mut builder = Biscuit::builder();
    facts.iter().try_for_each(|row| {
        builder.add_fact(fact("sql", &[string(row.get(0))]))
    })?;

    tx.commit().await?;

    Ok((
        [(SET_COOKIE, Cookie::build(("auth", builder.build(&root)?.to_base64()?))
            .http_only(true)
            .secure(false) // @TODO
            .same_site(cookie::SameSite::Lax) // Strict breaks sending cookie after email challenge redirect
            .max_age(cookie::time::Duration::seconds(60 * 60 * 24 * 365))
            .to_string()
        )],
        query.redirect
            .map(|r| Redirect::to(&r).into_response())
            .unwrap_or(NoContent.into_response())
    ))
}

async fn pre<'a>(tx: &mut Transaction<'a>, biscuit: &Option<extract::biscuit::Biscuit>, anon_role: &String, query: &'a Query) -> Result<(), HttpgError> {

    tx.batch_execute(&format!("set local role to {anon_role}")).await?;

    if let Some(lang) = &query.accept_language {
        let mut lang = lang.split(",").next().unwrap_or("en-US").replace("-", "_");
        lang.push_str(".UTF8");

        let params: [(&(dyn ToSql + Sync), Type); 1] = [
            (
                &lang,
                Type::TEXT
            )
        ];
        
        let stx = tx.savepoint("lc_time").await?;

        let res = stx.query_typed("select set_config('lc_time', $1, true)", &params).await;

        match res {
            Ok(_) => stx.commit().await?,
            Err(_) => stx.rollback().await?,
        }
    }

    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![
        (
            serde_json::to_string(&query)?,
            Type::TEXT
        )
    ])
    .await?;

    if let Some(extract::biscuit::Biscuit(b)) = biscuit {
        futures::future::join_all(b.iter().map(async |sql| {
            tx.batch_execute(sql).await
        })).await;
    }

    Ok(())
}

#[debug_handler]
async fn email(
    State(AppState {write_pool, config: HttpgConfig { smtp_sender, smtp_user, smtp_password, smtp_relay, anon_role, ..}, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {

    let mut conn = write_pool.get().await?;
    let mut tx = conn.build_transaction()
        .isolation_level(IsolationLevel::Serializable)
        .start().await
    ?;

    pre(&mut tx, &biscuit, &anon_role, &query).await?;

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param as &(dyn ToSql + Sync), param.to_owned().into())
    }).collect();

    let rows = tx.query_typed_raw(&query.sql.to_owned(), sql_params).await?;

    let creds = Credentials::new(smtp_user, smtp_password);

    let mailer: AsyncSmtpTransport<Tokio1Executor> =
        AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&smtp_relay)
            .unwrap()
            .credentials(creds)
            .build();

    rows.err_into::<HttpgError>().try_for_each(async |row| {
        let email = Message::builder()
            .sender(smtp_sender.parse()?)
            .from(row.get::<&str, &str>("from").parse()?)
            .to(row.get::<&str, &str>("to").parse()?)
            .subject(row.get::<&str, &str>("subject"))
            .header(ContentType::TEXT_HTML)
            .body(row.get::<&str, &str>("html").to_string())
        ?;
        mailer.send(email).await?;
        Ok(())
    }).await?;

    tx.commit().await?;

    Ok(query.redirect
        .map(|r| Redirect::to(&r).into_response())
        .unwrap_or(NoContent.into_response())
    )
}

#[debug_handler]
async fn stream_query(
    State(AppState {read_pool, config: HttpgConfig {anon_role, ..}, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {
    let mut conn = read_pool.get().await?;
    let mut tx = conn.build_transaction()
        .read_only(true)
        .isolation_level(IsolationLevel::RepeatableRead)
        .start().await?
    ;

    pre(&mut tx, &biscuit, &anon_role, &query).await?;

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param, param.to_owned().into())
    }).collect();

    let rows = tx.query_typed_raw(&query.sql.to_owned(), sql_params).await?;

    Ok(response::HttpResult {
        query: query.to_owned(),
        rows: response::Rows::Stream(rows)
        
    })

}

#[debug_handler]
async fn post_query(
    State(AppState {write_pool, config: HttpgConfig {anon_role, ..}, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {
    let mut conn = write_pool.get().await?;
    let mut tx = conn.build_transaction().isolation_level(IsolationLevel::Serializable).start().await?;

    pre(&mut tx, &biscuit, &anon_role, &query).await?;

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param as &(dyn ToSql + Sync), param.to_owned().into())
    }).collect();

    let result = tx.query_typed(&query.sql, &sql_params).await;

    let rows = match result {
        Ok(rows) => {
            tx.commit().await?;

            if let Some(redirect) = query.redirect {
                return Ok(Redirect::to(&redirect).into_response());
            }

            rows
        },
        Err(err) => {
            let errors = json!({"error": &err.as_db_error().map(|e| e.message()).or(Some(&err.to_string()))});

            let mut conn = write_pool.get().await?;
            let mut tx = conn.build_transaction().read_only(true).isolation_level(IsolationLevel::Serializable).start().await?;

            pre(&mut tx, &biscuit, &anon_role, &query).await?;

            tx.query_typed_raw(
                "select set_config('httpg.errors', $1, true)",
                vec![(serde_json::to_string(&errors)?, Type::TEXT)])
            .await?;

            match &query.on_error {
                Some(on_error) => {
                    let rows: Vec<String> = tx
                        .query_typed(on_error.as_str(), &[])
                        .await
                        ?
                        .iter()
                        .map(|row| row.get(0))
                        .collect()
                    ;
                    return Ok((
                        StatusCode::BAD_REQUEST,
                        Html(rows.join(" \n"))
                    ).into_response());
                }
                _ => {
                    return Ok((
                        StatusCode::INTERNAL_SERVER_ERROR,
                        err.to_string(),
                    ).into_response());
                }
            }
        }
    };

    Ok(response::HttpResult {
        query,
        rows: response::Rows::Vec(rows)
    }.into_response())
}

#[debug_handler]
async fn raw_http(
    State(AppState {write_pool, config: HttpgConfig {anon_role, ..}, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<Response, HttpgError> {
    let mut conn = write_pool.get().await?;
    let mut tx = conn.build_transaction().isolation_level(IsolationLevel::Serializable).start().await?;

    pre(&mut tx, &biscuit, &anon_role, &query).await?;

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param as &(dyn ToSql + Sync), param.to_owned().into())
    }).collect();

    let result = tx.query_typed(&query.sql, sql_params.as_slice()).await?;

    tx.commit().await?;

    Ok(response::HttpResult {
        query,
        rows: response::Rows::Raw(result.iter()
            .map(|row| serde_json::from_str::<Raw>(row.get::<usize, String>(0).as_str()).unwrap())
            .collect()
        )
    }.into_response())
}

#[derive(Debug)]
pub struct NoCertificateVerification {}

impl rustls::client::danger::ServerCertVerifier for NoCertificateVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}

