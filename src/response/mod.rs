use axum::{body::Body, response::{Html, IntoResponse, Redirect, Response}};

use crate::extract::query::Query;

pub enum Rows {
    Stream(Body),
    Vec(Vec<String>),
}

pub struct Result {
    pub query: Query,
    pub rows: Rows,
}

impl IntoResponse for Result {
    fn into_response(self) -> Response {
        if let Some(redirect) = self.query.redirect {
            return Redirect::to(&redirect).into_response();
        }
        match self.query.accept { // @TODO real negotation parsing
            Some(a) if a == "application/json" => {
                match self.rows {
                    Rows::Stream(rows) =>  ([("content-type", "application/json")], rows).into_response(),
                    Rows::Vec(rows) => Html(
                        rows.into_iter().map(|r| r.to_string()).collect::<Vec<String>>().join(" \n")
                    ).into_response()
                }
                    
            },
            _ => {
                match self.rows {
                    Rows::Stream(rows) => Html(rows).into_response(),
                    Rows::Vec(rows) => Html(
                        rows.into_iter().map(|r| r.to_string()).collect::<Vec<String>>().join(" \n")
                    ).into_response(),
                }
            },
        }
    }
}
  
