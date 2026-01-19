mod extract;
mod sql;
mod response;
mod postgres;

use crate::postgres::{DeadPoolConfig, PostgresConn};

use http::Uri;
use axum::{
    Router, extract::{DefaultBodyLimit, State}, http::{
        StatusCode, header::SET_COOKIE,
    }, response::{Html, IntoResponse, NoContent, Redirect, Response}, routing::{get, post}
};
use axum_extra::extract::{cookie::Cookie};
use axum_server::tls_rustls::RustlsConfig;
use axum_macros::debug_handler;
use conf::Conf;

use config::ConfigError;
use cookie::time::{Duration, OffsetDateTime};
use futures::{StreamExt, TryStreamExt};
use lettre::{
    message::header::ContentType, transport::smtp::authentication::Credentials, AsyncSmtpTransport,
    AsyncTransport, Message, Tokio1Executor,
};
use serde_json::json;
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir, trace::TraceLayer};
use web_push::{ContentEncoding, HyperWebPushClient, SubscriptionInfo, VapidSignatureBuilder, WebPushClient, WebPushMessageBuilder};
use core::{panic};
use std::{fs::{self, File}, net::TcpListener};
use std::env;
use std::net::SocketAddr;
use tokio_postgres::{IsolationLevel};
use tokio_postgres::types::{ToSql, Type};
use deadpool_postgres::{CreatePoolError, Pool, PoolError, Transaction};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use biscuit_auth::{KeyPair, PrivateKey, Biscuit, builder::*};

use crate::{extract::query::{Query}};
use crate::response::compress_stream;

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

#[derive(Clone, Conf)]
struct TlsConfig {
    #[conf(env, value_parser = |file: &str| -> Result<_, HttpgError> { Ok(fs::read_to_string(file)?) })]
    pem: String,
    #[conf(env, value_parser = |file: &str| -> Result<_, HttpgError> { Ok(fs::read_to_string(file)?) })]
    pem_key: String,
}

#[derive(Clone, Conf)]
#[conf(env_prefix="HTTPG_")]
struct HttpgConfig {
    #[conf(env, value_parser = |file: &str| -> Result<_, HttpgError> { Ok(hex::decode(fs::read_to_string(file)?)?) })]
    private_key: Vec<u8>,
    #[conf(env)]
    webpush_private_key_file: Option<String>,
    #[conf(env)]
    smtp_sender: String,
    #[conf(env)]
    smtp_user: String,
    #[conf(env, value_parser = |file: &str| -> Result<_, HttpgError> { Ok(fs::read_to_string(file)?) })]
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
        Ok(Self::parse())
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
        .with(tracing_subscriber::fmt::layer().json().flatten_event(true))
        .init();


    let httpg_config = HttpgConfig::from_env()?;

    let read_pool = DeadPoolConfig::read()?.create_pool()?;
    let write_pool = DeadPoolConfig::write()?.create_pool()?;
    
    let state = AppState {
        read_pool,
        write_pool,
        config: httpg_config.to_owned(),
    };

    let app = Router::new()
        .route("/", get(index))
        .route("/logout", get(logout).post(logout))
        .route("/query", get(stream_query).post(post_query))
        .route("/raw", get(raw_http).post(raw_http))
        .route("/email", post(email))
        .route("/http", get(http).post(http))
        .route("/webpush", get(web_push).post(web_push))
        // .layer(axum::middleware::from_fn_with_state(state.clone(), pre))
        .route("/login", get(login).post(login))
        .fallback_service(ServeDir::new("public"))
        .with_state(state.to_owned())
        .layer(ServiceBuilder::new()
            .layer(DefaultBodyLimit::disable()) //max(1024 * 100))
            .layer(axum::middleware::from_fn(compress_stream::compress_stream))
            .layer(TraceLayer::new_for_http())
            .layer(CorsLayer::new().allow_origin(Any))
        )
    ;
    tokio::spawn(async move {

        let mut cfg = PostgresConn::from_env();
        let (client, mut conn) = cfg.connect().await?;

        let mut stream = futures::stream::poll_fn(move |cx| conn.poll_message(cx));

        let state = axum::extract::State(state);

        client.simple_query("listen web_push").await?;
        // client.simple_query("listen job").await?;

        while let Some(Ok(m)) = stream.next().await {
            match m {
                tokio_postgres::AsyncMessage::Notice(n) => tracing::info!("{n:#?}"),
                tokio_postgres::AsyncMessage::Notification(n) => {
                    match n.channel() {
                        "web_push" => {
                            let res = web_push(
                                    state.to_owned(),
                                    None,
                                    Query::default()
                                )
                                .await?
                                .into_response()
                            ;
                            dbg!(&res);
                        }
                        _ => todo!("{n:#?}")
                    }
                },
                _ => todo!(),
            }
        }

        Ok::<(), HttpgError>(())
    });

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
            ).await?;

            axum_server::from_tcp_rustls(tcp, config)?
                .serve(app.into_make_service())
            .await?
        },
        None => {
            tcp.set_nonblocking(true)?;

            axum_server::from_tcp(tcp)?
                .serve(app.into_make_service())
            .await?
        },
    };
    Ok(())
}

#[debug_handler]
async fn index(
    state: State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    mut query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {

    query.sql = state.config.index_sql.to_owned();

    stream_query(state.to_owned(), biscuit, query).await
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
            .same_site(cookie::SameSite::Lax) // Strict breaks setting cookie after cross-origin redirect
            .max_age(cookie::time::Duration::seconds(60 * 60 * 24 * 365))
            .to_string()
        )],
        Redirect::to(query.redirect.as_deref().unwrap_or("/")).into_response()
    ))
}

#[debug_handler]
async fn logout(
    query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {
    Ok((
        [
            (SET_COOKIE, Cookie::build(("auth", ""))
                .http_only(true)
                .secure(false) // @TODO
                .same_site(cookie::SameSite::Lax)
                .expires(OffsetDateTime::now_utc() - Duration::days(365))
                .to_string()
            ),
        ],
        Redirect::to(query.redirect.as_deref().unwrap_or("/")).into_response()
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

    let rows = tx.query_typed_raw(query.sql.as_ref(), sql_params).await?;

    let creds = Credentials::new(smtp_user, smtp_password);

    let mailer = AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&smtp_relay)?
        .credentials(creds)
        .build()
    ;

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
async fn http(
    State(AppState {write_pool, config: HttpgConfig { anon_role, ..}, ..}): State<AppState>,
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

    let rows = tx.query_typed_raw(query.sql.as_ref(), sql_params).await?;

    let client = reqwest::Client::new();
    rows.err_into::<HttpgError>().try_for_each(async |row| {
        let builder = match row.get::<&str, &str>("method") {
            "POST" =>  client.post(row.get::<&str, &str>("url")),
            _ =>  client.get(row.get::<&str, &str>("url")),
        };
        let res = builder
            .header("TTL", 2419200)
            .send()
        .await?;
        dbg!(&res);
        Ok(())
    }).await?;

    tx.commit().await?;

    Ok(query.redirect
        .map(|r| Redirect::to(&r).into_response())
        .unwrap_or(NoContent.into_response())
    )
}

#[debug_handler]
async fn web_push(
    State(AppState {read_pool, config: HttpgConfig { anon_role, webpush_private_key_file, ..}, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {

    let mut conn = read_pool.get().await?;
    let mut tx = conn.build_transaction()
        .isolation_level(IsolationLevel::RepeatableRead)
        .start().await
    ?;

    pre(&mut tx, &biscuit, &anon_role, &query).await?;

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param as &(dyn ToSql + Sync), param.to_owned().into())
    }).collect();

    let rows = tx.query_typed_raw(query.sql.as_ref(), sql_params).await?;

    let client = HyperWebPushClient::new();

    let private_key = File::open(webpush_private_key_file.as_ref().ok_or(HttpgError::WebPushPrivateKey)?)?;

    let n = rows.err_into::<HttpgError>().try_fold(0, async |acc, row| {
        let subscription_info = SubscriptionInfo::new(
            row.get::<&str, &str>("endpoint"),
            row.get::<&str, &str>("p256dh"),
            row.get::<&str, &str>("auth"),
        );

        let mut builder = WebPushMessageBuilder::new(&subscription_info);
        builder.set_payload(ContentEncoding::Aes128Gcm, row.get::<&str, &[u8]>("content"));

        let sig_builder = VapidSignatureBuilder::from_pem(
            &private_key,
            &subscription_info
        )?.build()?;

        builder.set_vapid_signature(sig_builder);

        client.send(builder.build()?).await?;
        Ok(acc + 1)
    }).await;

    tx.commit().await?;

    let redirect = query.redirect.as_deref().unwrap_or("/").parse::<Uri>()?;
    let serde_qs = serde_qs::Config::new().max_depth(0).use_form_encoding(true);

    let mut qs = match redirect.query() {
        Some(r) => {
            serde_qs.deserialize_str::<serde_json::Map<String, serde_json::Value>>(r)?
        },
        None => serde_json::Map::new(),
    };
    match n {
        Ok(n) if n > 0 => {
            qs.insert("flash[green]".into(), "notified".into());
        },
        Err(e) => {
            tracing::error!("{e:#?}");
        },
        _ => {
            qs.insert("flash[yellow]".into(), "could not notify".into());
        }
    }

    let builder = http::uri::Builder::from(redirect.to_owned());
    let builder = builder.path_and_query([redirect.path(), "?", serde_qs::to_string(&qs)?.as_str()].join(""));

    Ok(Redirect::to(builder.build()?.to_string().as_str()).into_response())
}

#[debug_handler]
async fn stream_query(
    State(AppState {read_pool, write_pool, config: HttpgConfig {anon_role, ..}, ..}): State<AppState>,
    biscuit: Option<extract::biscuit::Biscuit>,
    query: extract::query::Query,
) -> Result<impl IntoResponse, HttpgError> {

    let mut conn = match query.use_primary {
        Some(_) => write_pool,
        None => read_pool,
    }.get().await?;

    let mut tx = conn.build_transaction()
        .read_only(true)
        .isolation_level(IsolationLevel::RepeatableRead)
        .start().await?
    ;

    pre(&mut tx, &biscuit, &anon_role, &query).await?;

    let sql_params: Vec<(_, Type)> = query.params.iter().map(|param| {
        (param, param.to_owned().into())
    }).collect();

    let rows = tx.query_typed_raw(query.sql.as_ref(), sql_params).await?;

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
        rows: response::Rows::StringVec(rows)
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
        rows: response::Rows::Raw(result)
    }.into_response())
}
