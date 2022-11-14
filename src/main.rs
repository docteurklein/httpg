use axum::{
    extract::{Extension, Path, Query},
    http::{StatusCode, header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION}},
    routing::get,
    Router,
    response::{Json, Html, IntoResponse, Response},
};
use handlebars::Handlebars;
use std::env;
use std::cmp::min;
use std::collections::HashMap;
use serde::{Deserialize};
use serde_json::{Value};
use bb8::{Pool};
use bb8_postgres::PostgresConnectionManager;
use std::net::SocketAddr;
use tokio_postgres::NoTls;
use tokio_postgres::types::ToSql;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};


#[derive(Clone, Debug, Deserialize)]
struct Table {
    escaped_fqn: String,
    alias: String,
    cols: Value,
}

#[derive(Clone, Debug)]
struct State {
    pool: Pool<PostgresConnectionManager<NoTls>>,
    tables: HashMap<String, Table>,
    max_limit: u16,
    max_offset: u16,
    anon_role: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            env::var("RUST_LOG").unwrap_or_else(|_| "httpg=debug".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let (client, connection) = tokio_postgres::connect(&env::var("HTTPG_CONN").unwrap(), NoTls).await.unwrap(); // @TODO use pool?

    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("connection error: {}", e);
        }
    });

    let env_schema = env::var("HTTPG_SCHEMA").unwrap_or("public".to_string());
    let schemas: Vec<&str> = env_schema.split(",").collect();

    let table_defs = client.query(r#"
        select format('%s.%s', n.nspname, c.relname) fqn,
        format('%I.%I', n.nspname, c.relname) escaped_fqn,
        format('%I', c.relname || '_') alias,
        jsonb_object_agg(format('%s.%s', c.relname, a.attname), jsonb_build_object(
            'escaped_name', format('%I', a.attname),
            'type', t.typname
        )) cols
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        join pg_catalog.pg_attribute a on a.attrelid = c.oid
        join pg_catalog.pg_type t on t.oid = a.atttypid
        where c.relkind = any (array['r', 'v', 'm', 'f', 'p'])
        and a.attnum > 0
        and n.nspname = any($1)
        group by n.nspname, c.relname
    "#, &[&schemas]).await.unwrap();

    let manager = PostgresConnectionManager::new_from_stringlike(&env::var("HTTPG_CONN").unwrap(), NoTls).unwrap(); // @TOOO env vars
    let pool = Pool::builder().build(manager).await.unwrap();

    let state = State {
        pool,
        max_limit: env::var("HTTPG_MAX_LIMIT").unwrap_or("100".to_string()).parse::<u16>().unwrap(),
        max_offset: env::var("HTTPG_MAX_OFFSET").unwrap_or("0".to_string()).parse::<u16>().unwrap(),
        anon_role: env::var("HTTPG_ANON_ROLE").unwrap(),
        tables: table_defs.iter().map(|row| { (row.get("fqn"), Table {
            escaped_fqn: row.get("escaped_fqn"),
            alias: row.get("alias"),
            cols: row.get("cols"),
        })}).collect(),
    };
    eprintln!("{:?}", state.tables);

    let app = Router::new()
        .route("/:table", get(select))
        .layer(Extension(state))
    ;

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    tracing::debug!("listening on {}", addr);
    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}


async fn select(
    Extension(State {pool, tables, max_limit, max_offset, anon_role}): Extension<State>,
    headers: HeaderMap,
    Path(table): Path<String>,
    Query(query_params): Query<HashMap<String, String>>,
) -> Result<Response, (StatusCode, String)> {
    if !tables.contains_key(&table) {
        return Err((StatusCode::NOT_FOUND, format!("{} Not found", table)));
    }
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().read_only(true).start().await.map_err(internal_error)?;

    let role = headers.get(AUTHORIZATION).and_then(|value| value.to_str().ok()).unwrap_or(&anon_role);
    tx.execute("select set_config('role', $1, true)", &[&role]).await.map_err(internal_error)?; // @TODO crypto

    let table_def = tables.get(&table).unwrap();
    let where_clause: Vec<String> = query_params.keys().enumerate().map(|(i, col_name)| {
        let col = table_def.cols.get(col_name).unwrap();
        format!("{}.{} = ${}::text::{}", table_def.alias, col["escaped_name"], i + 1, col["type"]) // @TODO hacky cast cast?
    }).collect();

    let sql = format!("select row_to_json({}) from {} {} {} {} {} {} limit {} offset {}",
        &table_def.alias,
        &table_def.escaped_fqn,
        &table_def.alias,
        if where_clause.is_empty() {""} else {"where"},
        where_clause.join(" and "),
        if headers.contains_key("order-by") {"order by"} else {""},
        "", //headers.get("order-by").unwrap_or(),
        min(max_limit, headers.get("limit").unwrap_or(&HeaderValue::from_static("100")).to_str().map_err(internal_error)?.parse::<u16>().map_err(internal_error)?),
        min(max_offset, headers.get("offset").map(|header| {header.to_str()}).unwrap_or(Ok("0")).map_err(internal_error)?.parse::<u16>().map_err(internal_error)?),
    );
    let params: Vec<&(dyn ToSql + Sync)> = query_params.values().map(|value| {value as &(dyn ToSql + Sync)}).collect();
    let rows = tx.query(
        &sql, params.as_slice()
    ).await.map_err(internal_error)?;
    let res: Vec<Value> = rows.iter().map(|row| {row.get(0)}).collect();

    match headers.get(ACCEPT).unwrap().to_str() {
        Ok("text/html") => {
            let mut handlebars = Handlebars::new();
            handlebars.register_templates_directory("hbs", "./templates").map_err(internal_error)?;
            Ok(Html(handlebars.render(headers.get("template").unwrap().to_str().unwrap(), &res).unwrap()).into_response())
        },
        _ => Ok(Json(res).into_response()),
    }
}

fn internal_error<E>(err: E) -> (StatusCode, String)
where
    E: std::error::Error,
{
    eprintln!("{}", err);
    (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
}
