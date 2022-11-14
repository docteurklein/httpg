use axum::{
    extract::{Extension, Path, Query},
    http::{StatusCode, header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION}},
    routing::{get, post},
    Router,
    response::{Json, Html, IntoResponse, Response},
};
use handlebars::Handlebars;
use std::env;
use std::cmp::min;
use std::collections::HashMap;
use serde::{Deserialize};
use serde_json::{json, Value};
use bb8::{Pool};
use bb8_postgres::PostgresConnectionManager;
use std::net::SocketAddr;
use tokio_postgres::NoTls;
use tokio_postgres::types::ToSql;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};


#[derive(Clone, Debug, Deserialize)]
struct Relation {
    escaped_fqn: String,
    alias: String,
    cols: Value,
}

#[derive(Clone, Debug, Deserialize)]
struct Procedure {
    escaped_fqn: String,
    arguments: Value,
}

#[derive(Clone, Debug)]
struct State {
    pool: Pool<PostgresConnectionManager<NoTls>>,
    relations: HashMap<String, Relation>,
    procedures: HashMap<String, Procedure>,
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

    let relation_defs = client.query(r#"
        select format('%s.%s', n.nspname, r.relname) fqn,
        format('%I.%I', n.nspname, r.relname) escaped_fqn,
        format('%I', r.relname || '_') alias,
        jsonb_object_agg(format('%s.%s', r.relname, a.attname), jsonb_build_object(
            'escaped_name', quote_ident(a.attname),
            'type', t.typname,
            'fkey', c.conname,
            'target', rr.relname
        )) cols
        from pg_catalog.pg_class r
        left join pg_catalog.pg_constraint c on c.conrelid = r.oid
        left join pg_catalog.pg_class rr on c.confrelid = rr.oid
        join pg_catalog.pg_namespace n on n.oid = r.relnamespace
        join pg_catalog.pg_attribute a on a.attrelid = r.oid
        join pg_catalog.pg_type t on t.oid = a.atttypid
        where r.relkind = any (array['r', 'v', 'm', 'f', 'p'])
        and (c.contype = 'f' or c.contype is null)
        and a.attnum > 0
        and n.nspname = any($1)
        group by n.nspname, r.relname
    "#, &[&schemas]).await.unwrap();

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

    let manager = PostgresConnectionManager::new_from_stringlike(&env::var("HTTPG_CONN").unwrap(), NoTls).unwrap();
    let pool = Pool::builder().build(manager).await.unwrap();

    let state = State {
        pool,
        max_limit: env::var("HTTPG_MAX_LIMIT").unwrap_or("100".to_string()).parse::<u16>().unwrap(),
        max_offset: env::var("HTTPG_MAX_OFFSET").unwrap_or("0".to_string()).parse::<u16>().unwrap(),
        anon_role: env::var("HTTPG_ANON_ROLE").unwrap(),
        relations: relation_defs.iter().map(|row| { (row.get("fqn"), Relation {
            escaped_fqn: row.get("escaped_fqn"),
            alias: row.get("alias"),
            cols: row.get("cols"),
        })}).collect(),
        procedures: procedure_defs.iter().map(|row| { (row.get("fqn"), Procedure {
            escaped_fqn: row.get("escaped_fqn"),
            arguments: row.get("arguments"),
        })}).collect(),
    };
    eprintln!("{:?}", state);

    let app = Router::new()
        .route("/relation/:relation", get(select_rows))//.post(insert_rows).put(upsert_rows).delete(delete_rows))
        .route("/procedure/:procedure", post(call_procedure))
        .layer(Extension(state))
    ;

    let addr = SocketAddr::from(([127, 0, 0, 1], 3000));
    tracing::debug!("listening on {}", addr);
    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}


async fn select_rows(
    Extension(State {pool, relations, procedures, max_limit, max_offset, anon_role}): Extension<State>,
    headers: HeaderMap,
    Path(relation): Path<String>,
    Query(query_params): Query<HashMap<String, String>>,
) -> Result<Response, (StatusCode, String)> {
    if !relations.contains_key(&relation) {
        return Err((StatusCode::NOT_FOUND, format!("{} Not found", relation)));
    }
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().read_only(true).start().await.map_err(internal_error)?;

    let role = headers.get(AUTHORIZATION).and_then(|value| value.to_str().ok()).unwrap_or(&anon_role);
    tx.execute("select set_config('role', $1, true)", &[&role]).await.map_err(internal_error)?; // @TODO crypto

    let relation_def = relations.get(&relation).unwrap();
    let where_clause: Vec<String> = query_params.keys().enumerate().map(|(i, col_name)| {
        let col = relation_def.cols.get(col_name).unwrap();
        format!("{}.{} = ${}::text::{}", relation_def.alias, col["escaped_name"], i + 1, col["type"]) // @TODO hacky cast cast?
    }).collect();

    let sql = format!("select row_to_json({}) from {} {} {} {} {} {} limit {} offset {}",
        &relation_def.alias,
        &relation_def.escaped_fqn,
        &relation_def.alias,
        if where_clause.is_empty() {""} else {"where"},
        where_clause.join(" and "),
        if headers.contains_key("order-by") {"order by"} else {""},
        "", //headers.get("order-by").unwrap_or(), @TODO escape!
        min(max_limit, headers.get("limit").unwrap_or(&HeaderValue::from_static("100")).to_str().map_err(internal_error)?.parse::<u16>().map_err(internal_error)?),
        min(max_offset, headers.get("offset").map(|header| {header.to_str()}).unwrap_or(Ok("0")).map_err(internal_error)?.parse::<u16>().map_err(internal_error)?),
    );
    let params: Vec<&(dyn ToSql + Sync)> = query_params.values().map(|value| {value as &(dyn ToSql + Sync)}).collect();
    let rows = tx.query(
        &sql, params.as_slice()
    ).await.map_err(internal_error)?;
    let res: Vec<Value> = rows.iter().map(|row| {
        let mut r: Value = row.get(0);
        r["link"] = json!({
            "href": format!("/relation/{}", "public.comment")
        });
        r
    }).collect();

    match headers.get(ACCEPT).unwrap().to_str() { // @TODO real negotation parsing
        Ok("text/html") => {
            let mut handlebars = Handlebars::new(); // @TODO share instance
            handlebars.register_templates_directory("hbs", "./templates").map_err(internal_error)?;
            Ok(Html(handlebars.render(headers.get("template").unwrap().to_str().unwrap(), &res).unwrap()).into_response())
        },
        _ => Ok(Json(res).into_response()),
    }
}

async fn call_procedure(
    Extension(State {pool, relations, procedures, max_limit, max_offset, anon_role}): Extension<State>,
    headers: HeaderMap,
    Path(procedure): Path<String>,
    Query(query_params): Query<HashMap<String, String>>,
) -> Result<Response, (StatusCode, String)> {
    if !procedures.contains_key(&procedure) {
        return Err((StatusCode::NOT_FOUND, format!("{} Not found", procedure)));
    }
    let mut conn = pool.get().await.map_err(internal_error)?;
    let tx = conn.build_transaction().read_only(false).start().await.map_err(internal_error)?;

    let role = headers.get(AUTHORIZATION).and_then(|value| value.to_str().ok()).unwrap_or(&anon_role);
    tx.execute("select set_config('role', $1, true)", &[&role]).await.map_err(internal_error)?; // @TODO crypto

    let procedure_def = procedures.get(&procedure).unwrap();
    let args: Vec<String> = query_params.keys().enumerate().map(|(i, arg_name)| {
        let arg = procedure_def.arguments.get(arg_name).unwrap();
        format!("{} => ${}::text::{}", arg["escaped_name"], i + 1, arg["type"]) // @TODO hacky cast cast?
    }).collect();

    let sql = format!("call {}({})",
        &procedure_def.escaped_fqn,
        args.join(", ")
    );
    let params: Vec<&(dyn ToSql + Sync)> = query_params.values().map(|value| {value as &(dyn ToSql + Sync)}).collect();
    tx.execute(&sql, params.as_slice()).await.map_err(internal_error)?;
    tx.commit().await.map_err(internal_error)?;

    Ok((StatusCode::NO_CONTENT, "no content").into_response())
}

fn internal_error<E>(err: E) -> (StatusCode, String)
where
    E: std::error::Error,
{
    eprintln!("{}", err);
    (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
}
