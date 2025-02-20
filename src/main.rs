use axum::{
    body::{Body, Bytes}, extract::State, http::{
        header::{HeaderMap, SET_COOKIE},
        StatusCode,
    }, response::{Html, IntoResponse, Redirect, Response}, routing::{get, post}, Router
};
use axum_extra::extract::cookie::Cookie;
use axum_server::tls_rustls::RustlsConfig;
use axum_macros::debug_handler;
// use axum_server::tls_rustls::RustlsConfig;

// use futures::stream::Select;
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::fs;
use tokio_stream::StreamExt;
// use tokio_postgres_rustls::MakeRustlsConnect;
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir};
use core::panic;
use std::{net::TcpListener, sync::Arc};
use std::env;
use std::net::SocketAddr;
use tokio_postgres::{IsolationLevel, NoTls};
use tokio_postgres::types::{ToSql, Type};
use deadpool_postgres::{GenericClient, Pool, Runtime};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use biscuit_auth::{KeyPair, PrivateKey, Biscuit, builder::*};

mod extract;
mod sql;
mod response;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct DeadPoolConfig {
    #[serde(default)]
    pg: deadpool_postgres::Config,
}

impl DeadPoolConfig {
    pub fn from_env() -> Self {
        let config = config::Config::builder()
            .add_source(config::Environment::default().separator("__"))//.keep_prefix(true))
            .build()
            .unwrap();
        let cfg = config;

        cfg.try_deserialize::<Self>().unwrap()
    }
}

#[derive(Clone)]
struct AppState {
    pool: Pool,
    anon_role: String,
    private_key: PrivateKey,
}

#[tokio::main]
async fn main() -> Result<(), anyhow::Error> {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            env::var("RUST_LOG").unwrap_or("httpg=debug".to_string()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let cfg = DeadPoolConfig::from_env();

    let _tls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
        .with_no_client_auth()
    ;
    // let tls = MakeRustlsConnect::new(tls_config.into());
    
    let pool = cfg.pg.create_pool(Some(Runtime::Tokio1), NoTls)?;

    let pkey = fs::read(env::var("HTTPG_PRIVATE_KEY").expect("HTTPG_PRIVATE_KEY")).await?;

    
    let state = AppState {
        pool,
        anon_role: env::var("HTTPG_ANON_ROLE").expect("HTTPG_ANON_ROLE"),
        private_key: PrivateKey::from_bytes(&hex::decode(pkey)?)?,
    };

    let cors = CorsLayer::new()
        .allow_origin(Any);

    let app = Router::new()
        .route("/login", post(login))
        .route("/query", get(stream_query).post(post_query))
        .fallback_service(ServeDir::new("public"))
        .with_state(state)
        // .layer(CompressionLayer::new().br(true)) //nope with stream
        .layer(ServiceBuilder::new().layer(cors))
    ;

    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    let tcp = TcpListener::bind(addr)?;
    tracing::debug!("listening on https://{}", tcp.local_addr()?);

    let config = RustlsConfig::from_pem_file(
        "localhost+2.pem",
        "localhost+2-key.pem"
    )
    .await?;
    
    // axum_server::from_tcp(tcp)
    axum_server::from_tcp_rustls(tcp, config)
        .serve(app.into_make_service())
        .await?
    ;
    Ok(())
}

#[debug_handler]
async fn login(
    State(AppState {private_key, ..}): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, (StatusCode, String)> {
    let root = KeyPair::from(&private_key);

    let mut builder = Biscuit::builder();
    builder
        .add_fact(fact("sql", &[string("set local role to app; set local \"app.tenant\" to 'tenant#1';")]))
        .map_err(internal_error)?
    ;
    // @TODO challenge!

    Ok((
        [(SET_COOKIE, Cookie::new("auth", builder.build(&root).unwrap().to_base64().unwrap()).to_string())],
        Redirect::to(headers.get("referer").unwrap().to_str().unwrap())
    ).into_response())
}

#[debug_handler]
async fn stream_query(
    State(AppState {pool, anon_role, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<Response, (StatusCode, String)> {
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction()
        .read_only(true)
        .isolation_level(IsolationLevel::Serializable)
        .start().await
    .map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;

    if let Some(extract::biscuit::Biscuit(b)) = biscuit {
        tx.batch_execute(&b).await.map_err(internal_error)?;
    }

   let sql_params = query.params.iter().map(|param| {
        (param, Type::UNKNOWN)
    });
    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query.qs).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

    let rows = tx.query_typed_raw(&query.sql, sql_params).await.map_err(internal_error)?
        .map(|row| row.unwrap().get::<usize, String>(0))
    ;

    Ok(response::Result {
        query,
        rows: response::Rows::Stream(
            Body::from_stream(
                rows.map(|row| Bytes::from(row + "\n"))
                .map(Ok::<_, axum::Error>),
            )
        )
    }.into_response())

}
#[debug_handler]
async fn post_query(
    State(AppState {pool, anon_role, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    dbg!(&query);
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;

    if let Some(extract::biscuit::Biscuit(b)) = biscuit {
        tx.batch_execute(&b).await.map_err(internal_error)?;
    }

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param as &(dyn ToSql + Sync), Type::UNKNOWN)
    }).collect();

    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query.qs).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

    let result = tx.query_typed(&query.sql, sql_params.as_slice()).await;//.map_err(query_error);
    let rows: Vec<String> = match result {
         Ok(rows) => {
            tx.commit().await.map_err(internal_error)?;

            if let Some(redirect) = query.redirect {
                return Ok(Redirect::to(&redirect).into_response());
            }

             rows.iter().map(|row| {
                row.get(0)
            }).collect()
        },
        Err(err) => {
            let errors = json!({"error": err.to_string()});

            let mut conn = pool.get().await.map_err(internal_error)?;
            let tx = conn.build_transaction().read_only(true).isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

            tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query.qs).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;
            tx.query_typed_raw("select set_config('httpg.errors', $1, true)", vec![(serde_json::to_string(&errors).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

            match query.on_error {
                Some(on_error) => {
                    let rows: Vec<String> = tx
                        .query_typed(on_error.as_str(), &[]).await
                        .map_err(internal_error)?
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

    Ok(response::Result {
        query,
        rows: response::Rows::Vec(rows)
    }.into_response())
}

fn internal_error<E>(err: E) -> (StatusCode, String)
where
    E: std::error::Error,
{
    eprintln!("{}", err);
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        err.to_string(),
    )
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

