use axum::{
    body::{Body, Bytes}, extract::State, http::{
        header::{HeaderMap, ACCEPT, SET_COOKIE},
        StatusCode,
    }, response::{Html, IntoResponse, Redirect, Response}, routing::{get, post}, Json, Router
};
use axum_extra::extract::cookie::{CookieJar, Cookie};
use axum_server::tls_rustls::RustlsConfig;
use axum_macros::debug_handler;
// use axum_server::tls_rustls::RustlsConfig;

// use futures::stream::Select;
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlparser::{ast::{Expr, Ident, OrderBy, OrderByExpr, Query, SetExpr, TableFactor, TableWithJoins, VisitMut, VisitorMut}, dialect::PostgreSqlDialect, parser::Parser, tokenizer::Location};
use tokio::fs;
use tokio_stream::StreamExt;
// use tokio_postgres_rustls::MakeRustlsConnect;
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir};
use core::panic;
use std::{collections::BTreeMap, net::TcpListener, sync::Arc};
// use tracing::instrument::WithSubscriber;
use std::ops::ControlFlow;
use std::env;
use std::net::SocketAddr;
use tokio_postgres::{IsolationLevel, NoTls};
use tokio_postgres::types::{ToSql, Type};
use deadpool_postgres::{GenericClient, Pool, Runtime};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use biscuit_auth::{KeyPair, PrivateKey, Biscuit, builder::*};

mod extract;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct DeadPoolConfig {
    #[serde(default)]
    pg: deadpool_postgres::Config,
}

impl DeadPoolConfig {
    pub fn from_env() -> Self {
        let cfg = config::Config::builder()
            .add_source(config::Environment::default().separator("__"))//.keep_prefix(true))
            .build()
            .unwrap();

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
        .nest_service("/", ServeDir::new("public"))
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
    State(AppState {pool, private_key, anon_role}): State<AppState>,
    headers: HeaderMap,
    cookies: CookieJar,
    // Query(qs): Query<HashMap<String, String>>,
    mut query: extract::Query,
) -> Result<Response, (StatusCode, String)> {
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction()
        .read_only(true)
        .isolation_level(IsolationLevel::Serializable)
        .start().await
    .map_err(internal_error)?;

    let root = KeyPair::from(&private_key);
    if let Some(token) = cookies.get("auth") {
        let biscuit = Biscuit::from_base64(token.value(), root.public()).map_err(internal_error)?;

        let mut authorizer = biscuit.authorizer().map_err(internal_error)?;
        let sql: Vec<(String,)> = authorizer.query("sql($sql) <- sql($sql)").map_err(internal_error)?;

        tx.batch_execute(&sql.iter().map(|t| t.clone().0).collect::<Vec<String>>().join("; ")).await.map_err(internal_error)?;
    }
    else {
        tx.batch_execute(&format!("set local role {anon_role}")).await.map_err(internal_error)?;
    }

    let sql_params = query.params.iter().map(|param| {
        (param, Type::UNKNOWN)
    });
    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

    if let Ok(mut statements) = Parser::parse_sql(&PostgreSqlDialect{}, &query.sql) {
        statements.visit(&mut VisitOrderBy(query.reorder.clone()));
        query.sql = statements[0].to_string();
        dbg!(&query.sql);
    }

    let rows = tx.query_typed_raw(&query.sql, sql_params).await.map_err(internal_error)?
        .map(|row| row.unwrap().get::<usize, String>(0))
    ;

    if let Some(redirect) = query.redirect {
        return Ok(Redirect::to(&redirect).into_response());
    }


    match headers.get(ACCEPT).unwrap().to_str() { // @TODO real negotation parsing
        Ok("application/jsonl") => {
            Ok((
                [("content-type", "application/jsonl")],
                Body::from_stream(
                    rows.map(Bytes::from)
                    .map(Ok::<_, axum::Error>),
                )
            ).into_response())
        }
        Ok("application/json") => {
            Ok(Json(
                rows.collect::<Vec<String>>().await.join("\n")
            ).into_response())
        }
        _ => {
            Ok(Html(Body::from_stream(
                rows.map(|row| Bytes::from(row + "\n"))
                .map(Ok::<_, axum::Error>),
            )).into_response())
        },
    }
}
#[debug_handler]
async fn post_query(
    State(AppState {pool, private_key, anon_role, ..}): State<AppState>,
    headers: HeaderMap,
    cookies: CookieJar,
    query: extract::Query,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

    if let Some(token) = cookies.get("auth") {
        let root = KeyPair::from(&private_key);
        let biscuit = Biscuit::from_base64(token.value(), root.public()).map_err(internal_error)?;

        let mut authorizer = biscuit.authorizer().map_err(internal_error)?;
        let sql: Vec<(String,)> = authorizer.query("sql($sql) <- sql($sql)").map_err(internal_error)?;

        tx.batch_execute(&sql.iter().map(|t| t.clone().0).collect::<Vec<String>>().join("; ")).await.map_err(internal_error)?;
    }
    else {
        tx.batch_execute(&format!("set local role {anon_role}")).await.map_err(internal_error)?;
    }

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param as &(dyn ToSql + Sync), Type::UNKNOWN)
    }).collect();

    tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

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
            dbg!(&err);
            let errors = json!({"error": err.to_string()});

            let mut conn = pool.get().await.map_err(internal_error)?;
            let tx = conn.build_transaction().read_only(true).isolation_level(IsolationLevel::Serializable).start().await.map_err(internal_error)?;

            tx.query_typed_raw("select set_config('httpg.query', $1, true)", vec![(serde_json::to_string(&query).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;
            tx.query_typed_raw("select set_config('httpg.errors', $1, true)", vec![(serde_json::to_string(&errors).map_err(internal_error)?, Type::TEXT)]).await.map_err(internal_error)?;

            let rows: Vec<String> = tx.query_typed(query.on_error.unwrap().as_str(), &[]).await.map_err(internal_error)?.iter().map(|row| row.get(0)).collect();

            return Ok((
                StatusCode::BAD_REQUEST,
                Html(rows.join(" \n"))
            ).into_response());
        },
    };

    match headers.get(ACCEPT).unwrap().to_str() { // @TODO real negotation parsing
        Ok("application/json") => {
            Ok((
                [("content-type", "application/json")],
                Json(rows)
            ).into_response())
        }
        _ => {
            Ok(Html(
                rows.into_iter().map(|r| r.to_string()).collect::<Vec<String>>().join(" \n")
            ).into_response())
        },
    }
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

struct VisitOrderBy(BTreeMap<String, String>);

impl VisitorMut for VisitOrderBy {
  type Break = ();

  fn post_visit_query(&mut self, expr: &mut Query) -> ControlFlow<Self::Break> {
    if let Query { body, ..} = expr {
        if let SetExpr::Select(select) = &**body {

            if select.from.iter().any(|from| {
                match from {
                    TableWithJoins { relation: TableFactor::Table { alias: Some(alias), .. }, .. } => {
                        self.0.iter().any(|(rel, _col)| &alias.to_string() == rel )
                    }
                    _ => false
                }
            }) {
                expr.order_by = Some(OrderBy {
                    exprs: self.0.iter()
                        .map(|reorder| {
                            OrderByExpr {
                                expr: Expr::Identifier(Ident {
                                    value: reorder.1.to_string(),
                                    quote_style: None,
                                    span: sqlparser::tokenizer::Span { start: Location {line: 1, column: 1}, end: Location {line: 1, column: 1} }
                                }),
                                asc: None,
                                nulls_first: None,
                                with_fill: None,
                            }
                        })
                        .collect(),
                    interpolate: None,
                })
            }
        }
    }
    ControlFlow::Continue(())
  }
}
