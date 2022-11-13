use axum::{
    extract::{Extension, Path, Query, Json},
    http::{StatusCode},
    routing::get,
    Router,
};
use std::env;
use std::collections::HashMap;
use serde::{Deserialize};
use serde_json::{Value};
use bb8::{Pool};
use bb8_postgres::PostgresConnectionManager;
use std::net::SocketAddr;
use tokio_postgres::NoTls;
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
}

#[tokio::main]
async fn main() {
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::new(
            env::var("RUST_LOG").unwrap_or_else(|_| "pg_axum=debug".into()),
        ))
        .with(tracing_subscriber::fmt::layer())
        .init();

    let (client, connection) = tokio_postgres::connect("host=localhost user=florian password=florian", NoTls).await.unwrap(); // @TODO use pool?

    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("connection error: {}", e);
        }
    });

    let schemas = vec![env::var("PG_AXUM_SCHEMA").unwrap()];

    let rows = client.query(r#"
        select format('%s.%s', n.nspname, c.relname) fqn, format('%I.%I', n.nspname, c.relname) escaped_fqn, format('%I_alias', c.relname) alias,
        jsonb_object_agg(format('%s.%s', c.relname, a.attname), format('%I', a.attname)) cols
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        join pg_catalog.pg_attribute a on a.attrelid = c.oid
        where c.relkind = any (array['r', 'v', 'm', 'f', 'p'])
        and n.nspname = any($1)
        group by n.nspname, c.relname

    "#, &[&schemas]).await.unwrap();

    let manager = PostgresConnectionManager::new_from_stringlike("host=localhost user=florian password=florian", NoTls).unwrap(); // @TOOO env vars
    let pool = Pool::builder().build(manager).await.unwrap();

    let state = State {
        pool,
        tables: rows.iter().map(|row| { (row.get(0), Table {
            escaped_fqn: row.get(1),
            alias: row.get("alias"),
            cols: row.get("cols"),
        })}).collect(),
    };
    eprintln!("{:?}", state);

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
    Extension(State {pool, tables}): Extension<State>,
    Path(table): Path<String>,
    Query(query_params): Query<HashMap<String, String>>,
) -> Result<Json<Vec<Value>>, (StatusCode, String)> {
    if !tables.contains_key(&table) {
        return Err((StatusCode::NOT_FOUND, format!("{} Not found", table)));
    }
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().read_only(true).start().await.map_err(internal_error)?;

    tx.execute("select set_config('role', $1, true)", &[&"florian".to_string()]).await.map_err(internal_error)?;

    let table_def = tables.get(&table).unwrap();
    println!("{:?}", table_def);
    let where_clause: Vec<String> = query_params.keys().map(|col| {
        eprintln!("{:?}", col);
        format!("{}.{} = $1", table_def.alias, table_def.cols.get(col).unwrap())
    }).collect();

    let q = format!("select row_to_json({}) from {} {} where {}", &table_def.alias, &table_def.escaped_fqn, &table_def.alias, where_clause.join(" and "));
    let rows = tx.query(
        &q, &[&"test"] //&query_params.values().map(|value| {value}).collect()
    ).await.map_err(internal_error)?;
    let res: Vec<Value> = rows.iter().map(|row| {row.get(0)}).collect();

    Ok(Json(res))
}

fn internal_error<E>(err: E) -> (StatusCode, String)
where
    E: std::error::Error,
{
    eprintln!("{:?}", err);
    (StatusCode::INTERNAL_SERVER_ERROR, err.to_string())
}
