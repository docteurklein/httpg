use axum::{
    extract::{State, Path, Query, Json},
    http::{StatusCode, header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION}},
    routing::{get, post},
    Router,
    response::{Html, IntoResponse, Response},
};
use quaint::{val, col};
use quaint::{prelude::*, pooled::{PooledConnection, Quaint}};
use quaint::ast::*;
use quaint::visitor::{Visitor, Postgres};
use handlebars::Handlebars;
use std::time::Duration;
use std::env;
use std::fs;
use std::cmp::min;
use std::collections::HashMap;
use serde::{Deserialize};
use serde_json::{json, Value};
use std::net::SocketAddr;
use tokio_postgres::NoTls;
use tokio_postgres::types::ToSql;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};


#[derive(Clone, Debug, Deserialize)]
struct Relation {
    schema: String,
    name: String,
    alias: String,
    cols: Value,
    links: Value,
    f_links: Value,
    p_links: Value,
}

#[derive(Clone, Debug, Deserialize)]
struct Procedure {
    escaped_fqn: String,
    arguments: Value,
}

#[derive(Clone)]
struct AppState {
    pool: Quaint,
    relations: HashMap<String, Relation>,
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

    let (client, connection) = tokio_postgres::connect(&env::var("HTTPG_CONN").expect("HTTPG_CONN"), NoTls).await.unwrap(); // @TODO use pool?

    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("connection error: {}", e);
        }
    });

    let env_schema = env::var("HTTPG_SCHEMA").unwrap_or("public".to_string());
    let schemas: Vec<&str> = env_schema.split(",").collect();


    //let rel_defs_query = std::include_str!("../sql/relation_defs.sql");
    let rel_defs_query = fs::read_to_string("./sql/relation_defs.sql").expect("./sql/relation_defs.sql");
    let rel_defs = client.query(&rel_defs_query, &[&schemas]).await.unwrap();

    let procedure_defs = client.query(r#"
        with proc as (
            select p.*, n.nspname
            from pg_catalog.pg_proc p
            join pg_catalog.pg_namespace n on n.oid = p.pronamespace
            where p.prokind = any (array['p'])
            and n.nspname = any($1)
        )
        select format('%s.%s', p.nspname, p.proname) fqn,
        format('%I.%I', p.nspname, p.proname) escaped_fqn,
        jsonb_object_agg(a.name, jsonb_build_object(
            'escaped_name', quote_ident(a.name),
            'type', t.typname
        )) arguments
        from proc p,
        unnest(proargnames, proargtypes, proargmodes) with ordinality as a (name, type, mode, idx)
        join pg_catalog.pg_type t on t.oid = a.type
        group by p.nspname, p.proname
    "#, &[&schemas]).await.unwrap();

    let mut builder = Quaint::builder(&env::var("HTTPG_CONN").expect("HTTPG_CONN")).unwrap();
    builder.connection_limit(10);
    builder.max_idle_lifetime(Duration::from_secs(300));
    //builder.test_on_check_out(true);

    let pool = builder.build();

    let state = AppState {
        pool,
        max_limit: env::var("HTTPG_MAX_LIMIT").unwrap_or("100".to_string()).parse::<usize>().unwrap(),
        max_offset: env::var("HTTPG_MAX_OFFSET").unwrap_or("0".to_string()).parse::<usize>().unwrap(),
        anon_role: env::var("HTTPG_ANON_ROLE").expect("HTTPG_ANON_ROLE"),
        relations: rel_defs.iter().map(|row| { (row.get("fqn"), Relation {
            name: row.get("relname"),
            schema: row.get("nspname"),
            alias: row.get("alias"),
            cols: row.get("cols"),
            links: row.get("links"),
            f_links: row.get("f_links"),
            p_links: row.get("p_links"),
        })}).collect(),
        procedures: procedure_defs.iter().map(|row| { (row.get("fqn"), Procedure {
            escaped_fqn: row.get("escaped_fqn"),
            arguments: row.get("arguments"),
        })}).collect(),
    };
    dbg!(&state.relations);

    let app = Router::new()
        .route("/query", post(query))
        .route("/relation/:relation", get(select_rows).post(select_rows)) //.post(insert_rows).put(upsert_rows).delete(delete_rows))
        .route("/procedure/:procedure", post(call_procedure))
        .with_state(state)
    ;

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    tracing::debug!("listening on {}", addr);
    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}

#[derive(Debug, Deserialize)]
struct RawQuery {
    query: String,
    params: Value,
}

async fn query(
    State(AppState {pool, relations, max_limit, max_offset, anon_role, ..}): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<RawQuery>,
) -> Result<Response, (StatusCode, String)> {
    let role = headers.get(AUTHORIZATION).and_then(|value| value.to_str().ok()).unwrap_or(&anon_role); // @TODO crypto
    let conn = pool.check_out().await.map_err(internal_error)?;
    let tx = conn.start_transaction(Option::None).await.map_err(internal_error)?;

    tx.execute_raw("select set_config('role', $1, true)", &[role.into()]).await.map_err(internal_error)?;
    let rows = tx.query_raw(&body.query, &[quaint::Value::from(body.params)]).await.map_err(internal_error)?; // @TODO params
    tx.commit().await.map_err(internal_error)?;

    let res: Vec<Value> = rows.into_iter().map(|row| {
        dbg!(&row);
        let mut r: Value = row[0].as_json().unwrap().to_owned();
        //@TODO add hypermedia links
        r
    }).collect();

    match headers.get(ACCEPT).unwrap().to_str() { // @TODO real negotation parsing
        Ok("text/html") => {
            let mut handlebars = Handlebars::new(); // @TODO share instance
            handlebars.register_templates_directory("hbs", "./templates").map_err(internal_error)?;
            Ok(Html(handlebars.render(headers.get("template").unwrap().to_str().unwrap(), &res).unwrap()).into_response())
        },
        _ => Ok(axum::response::Json(res).into_response()),
    }
}

async fn select_rows(
    State(AppState {pool, relations, max_limit, max_offset, anon_role, ..}): State<AppState>,
    headers: HeaderMap,
    Path(relation): Path<String>,
    Query(params): Query<Params>,
    Query(conditions): Query<HashMap<String, String>>,
    //Json(body): Json<Value>,
) -> Result<Response, (StatusCode, String)> {
    let role = headers.get(AUTHORIZATION).and_then(|value| value.to_str().ok()).unwrap_or(&anon_role); // @TODO crypto
    if !relations.contains_key(&relation) {
        return Err((StatusCode::NOT_FOUND, format!("{} Not found", relation)));
    }
    let rel_def = relations.get(&relation).unwrap();

    let query = Select::from_table(Table::from((&rel_def.schema, &rel_def.name)).alias(&rel_def.alias))
        .value(row_to_json(&rel_def.alias, false))
        .limit(min(max_limit, params.limit.unwrap_or(100)))
        .offset(min(max_offset, params.offset.unwrap_or(0)))
    ;

    //let query = body.as_object().unwrap().into_iter().fold(query, |query, (key, value)| {

    let query = conditions.iter().fold(query, |query, (key, value)| {
        let col = rel_def.cols.get(key.clone()).unwrap();
        dbg!(col);
        query.and_where(Column::from((&rel_def.alias, key.clone())).equals(quaint::Value::from(value.clone())))
    });
    //let params: Vec<&(dyn ToSql + Sync)> = query_params.values().map(|value| {value as &(dyn ToSql + Sync)}).collect();

    let conn = pool.check_out().await.map_err(internal_error)?;
    let tx = conn.start_transaction(Option::None).await.map_err(internal_error)?;

    tx.execute_raw("select set_config('role', $1, true)", &[role.into()]).await.map_err(internal_error)?;
    tx.raw_cmd("select set_config('transaction_read_only', 'true', true)").await.map_err(internal_error)?;

    let rows = tx.select(query.into()).await.map_err(internal_error)?;

    let res: Vec<Value> = rows.into_iter().map(|row| {
        let mut r: Value = row[0].as_json().unwrap().to_owned();
        r["links"] = json!(rel_def.links);
        r
    }).collect();

    match headers.get(ACCEPT).unwrap().to_str() { // @TODO real negotation parsing
        Ok("text/html") => {
            let mut handlebars = Handlebars::new(); // @TODO share instance
            handlebars.register_templates_directory("hbs", "./templates").map_err(internal_error)?;
            Ok(Html(handlebars.render(headers.get("template").unwrap().to_str().unwrap(), &res).unwrap()).into_response())
        },
        _ => Ok(axum::response::Json(res).into_response()),
    }
}

async fn call_procedure(
    State(AppState {pool, procedures, anon_role, ..}): State<AppState>,
    headers: HeaderMap,
    Path(procedure): Path<String>,
    Query(query_params): Query<HashMap<String, String>>,
) -> Result<Response, (StatusCode, String)> {
    if !procedures.contains_key(&procedure) {
        return Err((StatusCode::NOT_FOUND, format!("{} Not found", procedure)));
    }
    //let mut conn = pool.get().await.map_err(internal_error)?;
    //let tx = conn.build_transaction().read_only(false).start().await.map_err(internal_error)?;

    //let role = headers.get(AUTHORIZATION).and_then(|value| value.to_str().ok()).unwrap_or(&anon_role);
    //tx.execute("select set_config('role', $1, true)", &[&role]).await.map_err(internal_error)?; // @TODO crypto

    //let procedure_def = procedures.get(&procedure).unwrap();
    //let args: Vec<String> = query_params.keys().enumerate().map(|(i, arg_name)| {
    //    let arg = procedure_def.arguments.get(arg_name).unwrap();
    //    format!("{} => ${}::text::{}", arg["escaped_name"], i + 1, arg["type"]) // @TODO hacky cast cast?
    //}).collect();

    //let sql = format!("call {}({})",
    //    &procedure_def.escaped_fqn,
    //    args.join(", ")
    //);
    //let params: Vec<&(dyn ToSql + Sync)> = query_params.values().map(|value| {value as &(dyn ToSql + Sync)}).collect();
    //tx.execute(&sql, params.as_slice()).await.map_err(internal_error)?;
    //tx.commit().await.map_err(internal_error)?;

    Ok((StatusCode::NO_CONTENT, "no content").into_response())
}

fn internal_error<E>(err: E) -> (StatusCode, String)
where
    E: std::error::Error,
{
    eprintln!("{}", err);
    (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
}

