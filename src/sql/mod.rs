use sqlparser::{ast::{Expr, Function, Ident, OrderBy, OrderByExpr, Query, SetExpr, Spanned, Statement, TableFactor, TableWithJoins, Visitor, VisitorMut}};
use std::{collections::BTreeMap, ops::{ControlFlow, Not}};

use crate::error::HttpgError;

pub struct VisitOrderBy(pub BTreeMap<String, serde_json::Value>);

#[derive(Debug)]
pub struct AllowList(pub Result<(), HttpgError>);

impl Visitor for AllowList {
    type Break = ();

    fn pre_visit_expr(&mut self, expr: &Expr) -> ControlFlow<Self::Break> {
        self.0 = match expr {
            Expr::Function(Function { name, ..}) if ["set_config", "current_setting"].contains(&name.to_string().as_str()) => {
                Err(HttpgError::RefusedSql {
                    query: expr.to_string(),
                    reason: Some(format!("illegal function: {name}")),
                })
            },
            _ => Ok(()),
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_statement(&mut self, statement: &Statement) -> ControlFlow<Self::Break> {
        self.0 = if matches!(*statement,
              Statement::Query(_)
            | Statement::Call(_)
            | Statement::Insert(_)
            | Statement::Update(_)
            | Statement::Delete(_)
        ) {
            Ok(())
        } else {
            Err(HttpgError::RefusedSql { query: statement.to_string(), reason: Some("only DML".to_string()) })
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_query(&mut self, query: &Query) -> ControlFlow<Self::Break> {
        self.0 = if matches!(*query.body,
              SetExpr::Select(_)
            | SetExpr::Values(_)
            | SetExpr::Insert(_)
            | SetExpr::Update(_)
            | SetExpr::Delete(_)
            | SetExpr::Merge(_)
            | SetExpr::Table(_)
            | SetExpr::SetOperation {..}
        ) {
            Ok(())
        } else {
            Err(HttpgError::RefusedSql { query: query.to_string(), reason: Some("only DML".to_string()) })
        };
        if self.0.is_err() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }
}

impl VisitorMut for VisitOrderBy {
    type Break = ();

    fn post_visit_query(&mut self, expr: &mut Query) -> ControlFlow<Self::Break> {
        expr.order_by = match &*expr.body {
            SetExpr::Select(select) => {
                self.order_by(select)
            }
            SetExpr::SetOperation {left, right, ..} => match (&**left, &**right) {
                (SetExpr::Select(select), _) => {
                    self.order_by(select)
                }
                (_, SetExpr::Select(select)) => {
                    self.order_by(select)
                }
                _ => None
            }
            _ => None
        };
        ControlFlow::Continue(())
    }
}

impl VisitOrderBy {
    pub(crate) fn order_by(&mut self, select: &sqlparser::ast::Select) -> Option<OrderBy> {
        let def = serde_json::Map::new();
        let exprs: Vec<OrderByExpr> = self.0.iter()
            .filter(|(rel, _)| {
                select.from.iter().any(|from| {
                    match from {
                        TableWithJoins { relation: TableFactor::Table { alias: Some(alias), .. }, .. } => {
                            alias.name.value.as_str() == rel.as_str()
                        }
                        _ => false
                    }
                })
        
            })
            .flat_map(|(rel, cols)| {
                cols.as_object().unwrap_or(&def).into_iter().map(move |(col, asc)| {
                    OrderByExpr {
                        expr: Expr::Identifier(Ident {
                            value: format!("{rel}.{col}"),
                            quote_style: None,
                            span: select.span(),
                        }),
                        options: sqlparser::ast::OrderByOptions {
                            // sort: Some(match asc.as_str() {
                            //     Some("desc") => sqlparser::ast::OrderBySort::Asc,
                            //     _ => sqlparser::ast::OrderBySort::Desc,
                            // }),
                            asc: Some(matches!(asc.as_str(), Some("desc")).not()),
                            nulls_first: None,
                        },
                        with_fill: None,
                    }
                })
            }).collect()
        ;

        (!exprs.is_empty()).then_some(OrderBy {
            kind: sqlparser::ast::OrderByKind::Expressions(exprs),
            interpolate: None,
        })
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
#[allow(clippy::indexing_slicing)]
mod tests {
    use serde_json::{Value, json};
    use sqlparser::{ast::{Statement, Visit, VisitMut}, dialect::PostgreSqlDialect, parser::Parser};

    use super::{AllowList, VisitOrderBy};
    use crate::error::HttpgError;

    fn parse(sql: &str) -> Vec<Statement> {
        Parser::parse_sql(&PostgreSqlDialect {}, sql).unwrap()
    }

    fn allowlist_result(sql: &str) -> Result<(), HttpgError> {
        let statements = parse(sql);
        // Start from an error so a visitor that never runs cannot look successful.
        let mut allowlist = AllowList(Err(HttpgError::Unknown));
        let _ = Visit::visit(&statements, &mut allowlist);
        allowlist.0
    }

    fn assert_refused(result: Result<(), HttpgError>, reason_fragment: &str) {
        assert!(
            matches!(
                &result,
                Err(HttpgError::RefusedSql { reason: Some(reason), .. })
                    if reason.contains(reason_fragment)
            ),
            "expected refused SQL containing {reason_fragment:?}, got {result:?}"
        );
    }

    fn ordering(map: Value) -> std::collections::BTreeMap<String, Value> {
        serde_json::from_value(map).unwrap()
    }

    fn apply_order(sql: &str, map: Value) -> String {
        let mut statements = parse(sql);
        let _ = VisitMut::visit(&mut statements, &mut VisitOrderBy(ordering(map)));
        statements.first().map(ToString::to_string).unwrap_or_default()
    }

    #[test]
    fn allowlist_accepts_dml_statements() {
        for sql in [
            "select 1",
            "insert into t (id) values (1)",
            "update t set id = 2",
            "delete from t",
            "call refresh()",
            "select 1; select 2",
        ] {
            assert!(allowlist_result(sql).is_ok(), "should be allowed: {sql}");
        }
    }

    #[test]
    fn allowlist_rejects_non_dml_statements() {
        for sql in ["create table t (id int)", "drop table t", "begin", "commit", "truncate t"] {
            let result = allowlist_result(sql);
            assert_refused(result, "only DML");
        }
    }

    #[test]
    fn allowlist_rejects_every_statement_in_a_batch() {
        assert_refused(allowlist_result("select 1; create table t (id int)"), "only DML");
    }

    #[test]
    fn allowlist_rejects_session_config_functions() {
        for sql in [
            "select set_config('x', 'y', true)",
            "select current_setting('x')",
            "select 1 where current_setting('x') = 'on'",
        ] {
            assert_refused(allowlist_result(sql), "illegal function");
        }
    }

    #[test]
    fn allowlist_allows_other_functions() {
        assert!(allowlist_result("select coalesce(null, now())").is_ok());
    }

    #[test]
    fn order_by_adds_qualified_columns() {
        let sql = apply_order("select id from things as t", json!({ "t": { "id": "asc" } }));
        assert!(sql.contains("ORDER BY t.id ASC"), "{sql}");
    }

    #[test]
    fn order_by_honors_desc_and_defaults_other_values_to_asc() {
        let sql = apply_order(
            "select id from things as t",
            json!({ "t": { "created": "desc", "name": "other" } }),
        );
        assert!(sql.contains("t.created DESC"), "{sql}");
        assert!(sql.contains("t.name ASC"), "{sql}");
    }

    #[test]
    fn order_by_ignores_unaliased_sources() {
        let sql = apply_order("select id from things", json!({ "things": { "id": "asc" } }));
        assert!(!sql.to_lowercase().contains("order by"), "{sql}");
    }

    #[test]
    fn order_by_ignores_unknown_relations() {
        let sql = apply_order("select id from things as t", json!({ "other": { "id": "asc" } }));
        assert!(!sql.to_lowercase().contains("order by"), "{sql}");
    }

    #[test]
    fn order_by_replaces_an_existing_order_by() {
        let sql = apply_order(
            "select id from things as t order by t.id asc",
            json!({ "t": { "id": "desc" } }),
        );
        assert!(sql.contains("ORDER BY t.id DESC"), "{sql}");
        assert!(!sql.contains("ASC"), "{sql}");
    }

    #[test]
    fn order_by_handles_a_set_operations_right_select() {
        let sql = apply_order(
            "values (1) union select id from things as t",
            json!({ "t": { "id": "asc" } }),
        );
        assert!(sql.contains("ORDER BY t.id ASC"), "{sql}");
    }

    #[test]
    fn order_by_leaves_values_queries_alone() {
        let sql = apply_order("values (1)", json!({ "t": { "id": "asc" } }));
        assert!(!sql.to_lowercase().contains("order by"), "{sql}");
    }
}


