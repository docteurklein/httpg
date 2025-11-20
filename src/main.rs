use axum::{
    extract::{DefaultBodyLimit, State}, http::{
        header::SET_COOKIE,
        StatusCode,
    }, response::{Html, IntoResponse, Redirect, Response}, routing::{get, post}, Router
};
use axum_extra::extract::cookie::{Cookie, SameSite::Strict};
use axum_server::{accept::Accept, tls_rustls::RustlsConfig};
use axum_macros::debug_handler;
// use axum_server::tls_rustls::RustlsConfig;

use email_clients::{clients::{get_email_client, smtp::SmtpConfig}, configuration::EmailConfiguration, email::{EmailAddress, EmailObject}};
use futures::StreamExt;
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::fs;
use tokio_postgres_rustls::MakeRustlsConnect;
// use tokio_postgres_rustls::MakeRustlsConnect;
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir};
use core::{panic};
use std::{net::TcpListener, sync::Arc};
use std::env;
use std::net::SocketAddr;
use tokio_postgres::{IsolationLevel, NoTls};
use tokio_postgres::types::{ToSql, Type};
use deadpool_postgres::{Pool, Runtime};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use biscuit_auth::{KeyPair, PrivateKey, Biscuit, builder::*};

use crate::response::Raw;

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
            .add_source(config::Environment::default()
                .prefix("PG")
                .separator("_")
                .keep_prefix(true))
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
    login_proc: String,
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

    let pool = match env::var("PG_SSLMODE") {
        Ok(_) => {
            let tls_config = rustls::ClientConfig::builder()
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
                .with_no_client_auth()
            ;
            let tls = MakeRustlsConnect::new(tls_config);

            cfg.pg.create_pool(Some(Runtime::Tokio1), tls)?
        },
        _ => cfg.pg.create_pool(Some(Runtime::Tokio1), NoTls)?,
    };
    
    let pkey = fs::read(env::var("HTTPG_PRIVATE_KEY").expect("HTTPG_PRIVATE_KEY")).await?;
    let login_proc = env::var("HTTPG_LOGIN_PROC").expect("HTTPG_LOGIN_PROC");
    
    let state = AppState {
        login_proc,
        pool,
        anon_role: env::var("HTTPG_ANON_ROLE").expect("HTTPG_ANON_ROLE"),
        private_key: PrivateKey::from_bytes(&hex::decode(pkey)?)?,
    };

    let cors = CorsLayer::new()
        .allow_origin(Any);

    let app = Router::new()
        .route("/login", post(login))
        .route("/query", get(stream_query).post(post_query))
        .route("/upload", post(upload_query))
        .route("/raw", get(raw_http).post(raw_http))
        .route("/email", post(email))
        .fallback_service(ServeDir::new("public"))
        .with_state(state)
        .layer(DefaultBodyLimit::disable()) //max(1024 * 100))
        // .layer(CompressionLayer::new().br(true)) //nope with stream
        .layer(ServiceBuilder::new().layer(cors))
    ;

    let addr = SocketAddr::from(([0, 0, 0, 0], env::var("PORT").unwrap_or("3000".to_string()).parse().unwrap_or(3000)));
    let tcp = TcpListener::bind(addr)?;
    tracing::debug!("listening on {}", tcp.local_addr()?);

    let config = RustlsConfig::from_pem_file(
        env::var("HTTPG_PEM").unwrap_or("".to_string()),
        env::var("HTTPG_PEM_KEY").unwrap_or("".to_string()),
    )
    .await;
    
    match config {
        Ok(config) =>  {
            axum_server::from_tcp_rustls(tcp, config)
            .serve(app.into_make_service())
            .await?
        },
        Err(_) => {
            axum_server::from_tcp(tcp)
            .serve(app.into_make_service())
            .await?
        },
    };
    Ok(())
}

#[debug_handler]
async fn login(
    State(AppState {pool, login_proc, anon_role, private_key, ..}): State<AppState>,
    query: extract::query::Query,
) -> Result<Response, Response> {
    let root = KeyPair::from(&private_key);

    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction()
        .isolation_level(IsolationLevel::Serializable)
        .start().await
    .map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;
    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![
        (
            serde_json::to_string(&query).map_err(internal_error)?,
            Type::TEXT
        )
    ])
    .await
    .map_err(internal_error)?;

    let row = tx.query_opt(&login_proc, &[]).await;

    let mut builder = Biscuit::builder();
    if let Ok(Some(row)) = row {
        builder
        .add_fact(fact("sql", &[string(row.get(0))]))
        .map_err(internal_error)?;
    }
    tx.commit().await.map_err(internal_error)?;

    Ok((
        [(SET_COOKIE, Cookie::build(("auth", builder.build(&root).unwrap().to_base64().unwrap()))
            .http_only(true)
            .secure(true)
            .same_site(Strict)
            .max_age(cookie::time::Duration::seconds(60 * 60 * 24 * 365))
            .to_string()
        )],
        Redirect::to(&query.redirect.unwrap())
    ).into_response())
}

#[debug_handler]
async fn email(
    State(AppState {pool, anon_role, ..}): State<AppState>,
    query: extract::query::Query,
) -> Result<Response, Response> {

    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction()
        .isolation_level(IsolationLevel::Serializable)
        .start().await
    .map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;
    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![
        (
            serde_json::to_string(&query).map_err(internal_error)?,
            Type::TEXT
        )
    ])
    .await
    .map_err(internal_error)?;

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param, param.to_owned().into())
    }).collect();

    let rows = tx.query_typed_raw(&query.sql.clone(), sql_params).await.map_err(internal_error)?;

    let smtp_config = SmtpConfig::default()
        .sender("florian.klein@free.fr")
        .username(env::var("HTTPG_SMTP_USER").unwrap())
        .password(env::var("HTTPG_SMTP_PASSWORD").unwrap())
        .relay(env::var("HTTPG_SMTP_RELAY").unwrap())
        .tls(email_clients::clients::smtp::TlsMode::StartTls)
        .port(587)
    ;
    let email_configuration: EmailConfiguration = smtp_config.into();
    let client = get_email_client(email_configuration);

    rows.for_each(async |row| {
        if let Ok(row) = row {
           let mail = EmailObject {
               sender: row.get::<&str, &str>("sender").into(),
               to: vec![EmailAddress { name: row.get::<&str, &str>("to").into(), email: row.get::<&str, &str>("to").into() }],
               subject: row.get::<&str, &str>("subject").into(),
               plain: row.get::<&str, &str>("plain").into(),
               html: row.get::<&str, &str>("html").into(),
            };
            dbg!(&mail);
            client.clone().unwrap().send_emails(mail).await.expect("Unable to send email");
        }
    }).await;

    tx.commit().await.map_err(internal_error)?;

    Ok(Redirect::to(&query.redirect.unwrap()).into_response())
}

#[debug_handler]
async fn stream_query(
    State(AppState {pool, anon_role, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<Response, Response> {
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction()
        .read_only(true)
        .isolation_level(IsolationLevel::Serializable)
        .start().await
    .map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;

    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![
        (
            serde_json::to_string(&query).map_err(internal_error)?,
            Type::TEXT
        )
    ])
    .await
    .map_err(internal_error)?;

    if let Some(extract::biscuit::Biscuit(b)) = biscuit {
        tx.batch_execute(&b).await.map_err(internal_error)?;
    }

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param, param.to_owned().into())
    }).collect();

    let rows = tx.query_typed_raw(&query.sql.clone(), sql_params).await.map_err(internal_error)?;

    Ok(response::Result {
        query: query.clone(),
        rows: response::Rows::Stream(rows)
        
    }.into_response())

}

#[debug_handler]
async fn post_query(
    State(AppState {pool, anon_role, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, Response> {
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;

    tx.query_typed("select set_config('httpg.query', $1, true)", &[
        (&serde_json::to_string(&query).unwrap(), Type::TEXT)
    ])
    .await
    .map_err(internal_error)?;

    if let Some(extract::biscuit::Biscuit(b)) = biscuit {
        tx.batch_execute(&b).await.map_err(internal_error)?;
    }

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param, param.to_owned().into())
    }).collect();

    let result = tx.query_typed_raw(&query.sql, sql_params).await;

    let rows = match result {
         Ok(rows) => {
            tx.commit().await.map_err(internal_error)?;

            if let Some(redirect) = query.redirect {
                return Ok(Redirect::to(&redirect).into_response());
            }

            rows
        },
        Err(err) => {
            dbg!(&err);
            let errors = json!({"error": &err.as_db_error().unwrap().message()});

            let mut conn = pool.get().await.map_err(internal_error)?;
            let tx = conn.build_transaction().read_only(true).isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

            tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;
            tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;
            tx.query_typed_raw("select set_config('httpg.errors', $1, true)", vec![(serde_json::to_string(&errors).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

            match query.on_error {
                Some(on_error) => {
                    let rows: Vec<String> = tx
                        .query_typed(on_error.as_str(), &[])
                        .await
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
        rows: response::Rows::Stream(rows)
    }.into_response())
}

#[debug_handler]
async fn upload_query(
    State(AppState {pool, anon_role, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, Response> {
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;

    tx.query_typed("select set_config('httpg.query', $1, true)", &[
        (&serde_json::to_string(&query).unwrap(), Type::TEXT)
    ])
    .await
    .map_err(internal_error)?;

    if let Some(extract::biscuit::Biscuit(b)) = biscuit {
        tx.batch_execute(&b).await.map_err(internal_error)?;
    }

    let sql_params: Vec<(_, Type)> = query.files.iter()
        .flat_map(|file| vec!(
            (file.content.as_ref(), Type::BYTEA),
            (file.file_name.as_ref(), Type::BYTEA),
            (file.content_type.as_ref(), Type::BYTEA),
        ))
    .collect();

    let result = tx.query_typed_raw(&query.sql, sql_params).await;

    let rows = match result {
         Ok(rows) => {
            tx.commit().await.map_err(internal_error)?;

            if let Some(redirect) = query.redirect {
                return Ok(Redirect::to(&redirect).into_response());
            }

            response::Rows::Stream(rows)
        },
        Err(err) => {
            dbg!(&err);
            let errors = json!({"error": &err.as_db_error().map(|e| e.message()).or(Some(&err.to_string()))});

            let mut conn = pool.get().await.map_err(internal_error)?;
            let tx = conn.build_transaction().read_only(true).isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

            tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;
            tx.query_typed_raw("select set_config('httpg.errors', $1, true)", vec![(serde_json::to_string(&errors).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

            match query.on_error {
                Some(on_error) => {
                    let rows: Vec<String> = tx
                        .query_typed(on_error.as_str(), &[])
                        .await
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
        rows,
    }.into_response())
}

#[debug_handler]
async fn raw_http(
    State(AppState {pool, anon_role, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<Response, Response> {
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

    tx.batch_execute(&format!("set local role to {anon_role}")).await.map_err(internal_error)?;

    tx.query_typed("select set_config('httpg.query', $1, true)", &[
        (&serde_json::to_string(&query).unwrap(), Type::TEXT)
    ])
    .await
    .map_err(internal_error)?;

    if let Some(extract::biscuit::Biscuit(b)) = biscuit {
        tx.batch_execute(&b).await.map_err(internal_error)?;
    }

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param as &(dyn ToSql + Sync), param.to_owned().into())
    }).collect();

    let result = tx.query_typed(&query.sql, sql_params.as_slice()).await.map_err(internal_error)?;

    tx.commit().await.map_err(internal_error)?;

    Ok(response::Result {
        query,
        rows: response::Rows::Raw(result.iter()
            .map(|row| serde_json::from_str::<Raw>(row.get::<usize, String>(0).as_str()).unwrap())
            .collect()
        )
    }.into_response())
}


fn internal_error<E>(err: E) -> Response
where
    E: std::error::Error,
{
    eprintln!("{}", err);
    dbg!(&err);
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        err.to_string(),
    ).into_response()
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

