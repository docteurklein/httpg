use sqlparser::{ast::{Expr, Function, Ident, OrderBy, OrderByExpr, Query, SetExpr, Spanned, Statement, TableFactor, TableWithJoins, VisitorMut}};
use std::{collections::BTreeMap, ops::{ControlFlow, Not}};

pub struct VisitOrderBy(pub BTreeMap<String, serde_json::Value>);

#[derive(Debug)]
pub struct Whitelist(pub Option<String>);

impl VisitorMut for Whitelist {
    type Break = ();

    fn pre_visit_expr(&mut self, expr: &mut Expr) -> ControlFlow<Self::Break> {
        self.0 = match expr {
            Expr::Function(Function { name, ..}) if name.to_string() == "set_config" => Some(expr.to_string()),
            _ => None,
        };
        if self.0.is_some() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_statement(&mut self, statement: &mut Statement) -> ControlFlow<Self::Break> {
        self.0 = if matches!(*statement,
              Statement::Query(_)
            | Statement::Call(_)
            | Statement::Insert(_)
            | Statement::Update(_)
            | Statement::Delete(_)
        ) {
            None
        } else {
            Some(statement.to_string())
        };
        if self.0.is_some() {
            return ControlFlow::Break(());
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_query(&mut self, query: &mut Query) -> ControlFlow<Self::Break> {
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
            None
        } else {
            Some(query.to_string())
        };
        if self.0.is_some() {
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
                            span: select.span(),
                        }),
                        options: sqlparser::ast::OrderByOptions {
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


