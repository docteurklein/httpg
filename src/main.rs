use axum::{
    body::{Body, Bytes}, extract::{Json, Query, State}, http::{
        header::{HeaderMap, ACCEPT, AUTHORIZATION},
        StatusCode,
    }, response::{Html, IntoResponse, Response}, routing::{get, post}, Router
};
use axum_extra::TypedHeader;
use axum_server::tls_rustls::RustlsConfig;
use futures::{stream, Stream};
use headers::{Authorization, authorization::Bearer};

use axum_macros::debug_handler;
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use tokio::{fs};
use tokio_stream::StreamExt;
use futures_util::{pin_mut, TryStreamExt};
use tokio_postgres_rustls::MakeRustlsConnect;
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir};
// use quaint::{val, col, Value};
use handlebars::Handlebars;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tracing::instrument::WithSubscriber;
use std::{collections::HashMap, net::TcpListener, pin::Pin, sync::Arc, time::Duration};
use std::env;
use std::net::SocketAddr;
use tokio_postgres::{tls::MakeTlsConnect, Client, Error};
use tokio_postgres::types::{FromSql, ToSql, Type};
use deadpool_postgres::{GenericClient, ManagerConfig, Pool, RecyclingMethod, Runtime};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use biscuit_auth::{KeyPair, PrivateKey, builder_ext::AuthorizerExt, error, macros::*, Biscuit};

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Config {
    #[serde(default)]
    pg: deadpool_postgres::Config,
}

impl Config {
    pub fn from_env() -> Self {
        let cfg = config::Config::builder()
            .add_source(config::Environment::default().separator("__"))//.keep_prefix(true))
            
            .build()
            .unwrap();

        let mut cfg = cfg.try_deserialize::<Self>().unwrap();
        cfg
    }
}


#[derive(Clone)]
struct AppState {
    pool: Pool,
    // anon_role: String,
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

    let cfg = Config::from_env();

    let tls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
        .with_no_client_auth()
    ;
    let tls = MakeRustlsConnect::new(tls_config.into());
    
    let pool = cfg.pg.create_pool(Some(Runtime::Tokio1), tls)?;

    let pkey = fs::read(env::var("HTTPG_PRIVATE_KEY").expect("HTTPG_PRIVATE_KEY")).await?;
    let pkey = hex::decode(pkey)?;

    let state = AppState {
        pool,
    //     anon_role: env::var("HTTPG_ANON_ROLE").expect("HTTPG_ANON_ROLE"),
        private_key: PrivateKey::from_bytes(&pkey)?,
    };

    let cors = CorsLayer::new()
        .allow_origin(Any);
    let app = Router::new()
        .route("/query", get(get_query).post(post_query))
        .nest_service("/", ServeDir::new("public"))
        .with_state(state)
        .layer(ServiceBuilder::new().layer(cors))
    ;

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
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

#[derive(Debug, Deserialize, ToSql)]
struct QueryBody {
    query: String,
    params: Vec<String>,
}

#[debug_handler]
async fn get_query(
    State(AppState {pool, ..}): State<AppState>,
    headers: HeaderMap,
    Query(qs): Query<HashMap<String, String>>,
) -> Result<Response, (StatusCode, String)> {
    let conn = pool.get().await.map_err(internal_error)?;

//     let sql = format!(r#"with record (record, rel) as (
//     {}
// )
// select to_jsonb(record), decorate(rel, to_jsonb(record), null, pkey, links)
// from record
// left join rel on rel.fqn = rel
//     "#, qs.get("q").expect("q"));

    let sql = qs.get("q").expect("q");

    let sqlParams: Vec<&(dyn ToSql + Sync)> = Vec::new();

    let rows = conn.query_raw(sql, sqlParams).await.map_err(internal_error)?
        .map(|row| row.unwrap().get::<usize, String>(0));

    match headers.get(ACCEPT).unwrap().to_str() { // @TODO real negotation parsing
        // Ok("application/json") => Ok(axum::response::Json(rows).into_response()),
        _ => {
            let mut handlebars = Handlebars::new(); // @TODO share instance
            handlebars.register_templates_directory(".hbs", "./templates").map_err(internal_error)?;

            // let name = headers.get("template").expect("template").to_str().unwrap();
            // let name = qs.get("template").expect("template");

            Ok(Html(Body::from_stream(
                rows.map(|row| Bytes::from(row + "\n"))
                // .throttle(Duration::from_millis(5))
                .map(Ok::<_, axum::Error>),
            )).into_response())

            // Ok(Html(
            //     handlebars.render(name, &rows).map_err(internal_error)?
            // ).into_response())
        },
    }
}

#[debug_handler]
async fn post_query(
    State(AppState {pool, private_key}): State<AppState>,
    headers: HeaderMap,
    // TypedHeader(auth): TypedHeader<Authorization<Bearer>>,
    Query(qs): Query<HashMap<String, String>>,
    Json(body): Json<QueryBody>,
) -> Result<Response, (StatusCode, String)> {
    let conn = pool.get().await.map_err(internal_error)?;
    let root = KeyPair::from(&private_key);

    let auth = headers.get(AUTHORIZATION).unwrap();
    // dbg!(&auth, &root.public());
    let biscuit = Biscuit::from_base64(&auth, root.public()).map_err(internal_error)?;

    let mut authorizer = biscuit.authorizer().map_err(internal_error)?;
    let sql: Vec<(String, )> = authorizer.query("sql($sql) <- sql($sql)").map_err(internal_error)?;
    conn.batch_execute(&sql.iter().map(|t| t.clone().0).collect::<Vec<String>>().join("; ")).await.map_err(internal_error)?;

    let sqlParams: Vec<&(dyn ToSql + Sync)> = body.params.iter().map(|x| x as &(dyn ToSql + Sync)).collect();

    let sql = format!(r#"with record (record, rel) as (
    {}
)
select decorate(rel, to_jsonb(record), null, pkey, links)
from record
left join rel on rel.fqn = rel
    "#, body.query);
    let rows: Vec<Value> = conn.query(&sql, &sqlParams).await.map_err(internal_error)?.iter().map(|row| {
        row.get(0)
    }).collect();

    match headers.get(ACCEPT).unwrap().to_str() { // @TODO real negotation parsing
        Ok("text/html") => {
            let mut handlebars = Handlebars::new(); // @TODO share instance
            handlebars.register_templates_directory(".hbs", "./templates").map_err(internal_error)?;

            // let name = headers.get("template").expect("template").to_str().unwrap();
            let name = qs.get("template").expect("template");

            Ok(Html(handlebars.render(name, &rows).map_err(internal_error)?).into_response())
        },
        _ => Ok(axum::response::Json(rows).into_response()),
    }
}

fn internal_error<E>(err: E) -> (StatusCode, String)
where
    E: std::error::Error,
{
    eprintln!("{}", err);
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        "internal error".to_string(),
    )
}

fn authorize(token: &Biscuit) -> Result<(), error::Token> {
    let operation = "read";

    // same as the `biscuit!` macro. There is also a `authorizer_merge!`
    // macro for dynamic authorizer construction
    let mut authorizer = authorizer!(
      r#"operation({operation});"#
    );

    // register a fact containing the current time for TTL checks
    authorizer.set_time();

    // add a `allow if true;` policy
    // meaning that we are relying entirely on checks carried in the token itself
    authorizer.add_allow_all();

    // link the token to the authorizer
    authorizer.add_token(token)?;

    let result = authorizer.authorize();

    // store the authorization context
    println!("{}", authorizer.to_base64_snapshot()?);

    let _ = result?;
    Ok(())
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
