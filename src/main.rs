use axum::{
    extract::{Json, Query, State},
    http::{
        header::{HeaderMap, ACCEPT, AUTHORIZATION},
        StatusCode,
    },
    response::{Html, IntoResponse, Response},
    routing::post,
    Router
};
use axum_extra::TypedHeader;
use headers::{Authorization, authorization::Bearer};

use axum_macros::debug_handler;
use tokio::{fs};
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir};
// use quaint::{val, col, Value};
use handlebars::Handlebars;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, net::TcpListener};
use std::env;
use std::net::SocketAddr;
use tokio_postgres::{NoTls, Error, Client};
use tokio_postgres::types::{FromSql, ToSql, Type};
use deadpool_postgres::{ManagerConfig, Pool, RecyclingMethod, Runtime};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use biscuit_auth::{KeyPair, PrivateKey, builder_ext::AuthorizerExt, error, macros::*, Biscuit};

#[derive(Debug, Deserialize, Serialize)]
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
async fn main() {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            env::var("RUST_LOG").unwrap_or("httpg=debug".to_string()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let cfg = Config::from_env();
    let pool = cfg.pg.create_pool(Some(Runtime::Tokio1), NoTls).unwrap();

    let pkey = fs::read(env::var("HTTPG_PRIVATE_KEY").expect("HTTPG_PRIVATE_KEY")).await.unwrap();
    let pkey = hex::decode(pkey).unwrap();

    let state = AppState {
        pool,
    //     anon_role: env::var("HTTPG_ANON_ROLE").expect("HTTPG_ANON_ROLE"),
        private_key: PrivateKey::from_bytes(&pkey).unwrap(),
    };

    let cors = CorsLayer::new()
        .allow_origin(Any);
    let app = Router::new()
        .route("/query", post(query))
        .nest_service("/", ServeDir::new("public"))
        .with_state(state)
        .layer(ServiceBuilder::new().layer(cors));

    let addr = SocketAddr::from(([127, 0, 0, 1], 0));
    let tcp = TcpListener::bind(addr).unwrap();
    tracing::debug!("listening on {}", tcp.local_addr().unwrap());
    axum::Server::from_tcp(tcp).unwrap()
        .serve(app.into_make_service())
        .await
        .unwrap();
}

#[derive(Debug, Deserialize, ToSql)]
struct QueryBody {
    query: String,
    params: Vec<String>,
}

#[debug_handler]
async fn query(
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
    let biscuit = Biscuit::from_base64(&auth, root.public()).unwrap(); // map_err(internal_error)?;

    let mut authorizer = biscuit.authorizer().unwrap();
    let sql: Vec<(String, )> = authorizer.query("sql($sql) <- sql($sql)").unwrap();
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
            handlebars.register_templates_directory("hbs", "./templates").map_err(internal_error)?;

            // let name = headers.get("template").expect("template").to_str().unwrap();
            let name = qs.get("template").expect("template");

            Ok(Html(handlebars.render(name, &rows).unwrap()).into_response())
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
