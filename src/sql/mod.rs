use sqlparser::{ast::{Expr, Ident, OrderBy, OrderByExpr, Query, SetExpr, TableFactor, TableWithJoins, VisitorMut}, tokenizer::Location};
use std::{collections::BTreeMap, ops::{ControlFlow, Not}};

// use crate::extract::query::Order;

pub struct VisitOrderBy(pub BTreeMap<String, serde_json::Value>);

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
        let exprs: Vec<OrderByExpr> = self.0.iter()
            .filter(|(rel, _)| {
                select.from.iter().any(|from| {
                    match from {
                        TableWithJoins { relation: TableFactor::Table { alias: Some(alias), .. }, .. } => {
                            &&alias.to_string() == rel
                        }
                        _ => false
                    }
                })
        
            })
            .flat_map(|(rel, cols)| {
                cols.as_object().unwrap().into_iter().map(move |(col, asc)| {
                    OrderByExpr {
                        expr: Expr::Identifier(Ident {
                            value: format!("{rel}.{col}"),
                            quote_style: None,
                            span: sqlparser::tokenizer::Span { start: Location {line: 1, column: 1}, end: Location {line: 1, column: 1} }
                        }),
                        asc: Some(matches!(asc.as_str(), Some("desc")).not()),
                        nulls_first: None,
                        with_fill: None,
                    }
                })
            }).collect()
        ;

        (!exprs.is_empty()).then_some(OrderBy {
            exprs,
            interpolate: None,
        })
    }
}


