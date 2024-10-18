use axum::{
    extract::{Json, Path, Query, State},
    http::{
        header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION},
        Method, StatusCode,
    },
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Router,
};
use axum_macros::debug_handler;
use tower::builder::ServiceBuilder;
use tower_http::{cors::{Any, CorsLayer}, services::ServeDir};
// use quaint::{val, col, Value};
use handlebars::Handlebars;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::cmp::min;
use std::collections::HashMap;
use std::env;
use std::fs;
use std::net::SocketAddr;
use std::time::Duration;
use tokio_postgres::{NoTls, Error, Client};
use tokio_postgres::types::{FromSql, ToSql, Type};
use deadpool_postgres::{Config, ManagerConfig, Pool, RecyclingMethod, Runtime};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

#[derive(Clone, Debug, Serialize, Deserialize, FromSql)]
struct Link {
    target: String,
    attributes: HashMap<String, Option<String>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, FromSql)]
struct RelationDef {
    fqn: String,
    alias: String,
    nspname: String,
    relname: String,
    cols: Value,
    in_links: Value,
    out_links: Value,
}

#[derive(Clone, Debug, Deserialize)]
struct Procedure {
    escaped_fqn: String,
    arguments: Value,
}

#[derive(Clone)]
struct AppState {
    pool: Pool,
    relations: HashMap<String, RelationDef>,
    procedures: HashMap<String, Procedure>,
    max_limit: usize,
    max_offset: usize,
    anon_role: String,
}

#[derive(Debug, Deserialize)]
struct Params {
    limit: Option<usize>,
    offset: Option<usize>,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            env::var("RUST_LOG").unwrap_or("httpg=debug".to_string()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let mut cfg = Config::new();
    cfg.user = Some("Florian-Klein".to_string());
    cfg.dbname = Some("httpg".to_string());
    cfg.host = Some("/run/user/1001/devenv-95a9151/postgres/".to_string());
    cfg.manager = Some(ManagerConfig {
        recycling_method: RecyclingMethod::Fast,
    });
    let pool = cfg.create_pool(Some(Runtime::Tokio1), NoTls).unwrap();

    let state = AppState {
        pool,
        max_limit: env::var("HTTPG_MAX_LIMIT")
            .unwrap_or("100".to_string())
            .parse::<usize>()
            .unwrap(),
        max_offset: env::var("HTTPG_MAX_OFFSET")
            .unwrap_or("0".to_string())
            .parse::<usize>()
            .unwrap(),
        anon_role: env::var("HTTPG_ANON_ROLE").expect("HTTPG_ANON_ROLE"),
        relations: HashMap::new(),
        procedures: HashMap::new(),
    };
    dbg!(&state.relations);

    let cors = CorsLayer::new()
        .allow_origin(Any);
    let app = Router::new()
        .route("/query", post(query))
        .nest_service("/", ServeDir::new("public"))
        .with_state(state)
        .layer(ServiceBuilder::new().layer(cors));

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    tracing::debug!("listening on {}", addr);
    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}

#[derive(Debug, Deserialize, ToSql)]
struct QueryBody {
    query: String,
    params: Vec<String>,
}

async fn query(
    State(AppState {pool, relations, max_limit, max_offset, anon_role, ..}): State<AppState>,
    headers: HeaderMap,
    Query(qs): Query<HashMap<String, String>>,
    Json(body): Json<QueryBody>,
) -> Result<Response, (StatusCode, String)> {
    let role = headers.get(AUTHORIZATION).and_then(|value| value.to_str().ok()).unwrap_or(&anon_role); // @TODO crypto
    let conn = pool.get().await.map_err(internal_error)?;

    // conn.execute("select set_config('role', $1, true)", &[&role]).await.map_err(internal_error)?;

    let sqlParams: Vec<&(dyn ToSql + Sync)> = body.params.iter().map(|x| x as &(dyn ToSql + Sync)).collect();

    let sql = format!(r#"with record (record, rel) as (
    {}
)
select decorate(rel, to_jsonb(record), null, pkey, in_links, out_links)
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
