
use axum::{
    extract::{FromRef, OptionalFromRequestParts}, http::request::Parts, response::Response,
};
use axum_extra::extract::CookieJar;
use biscuit_auth::KeyPair;

use crate::AppState;

pub struct Biscuit(pub String);

impl<S> OptionalFromRequestParts<S> for Biscuit
where
    AppState: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Option<Self>, Self::Rejection> {
        let state = AppState::from_ref(state);
        let root = KeyPair::from(&state.private_key);
        let cookies = CookieJar::from_headers(&parts.headers);
        match cookies.get("auth") {
            Some(token) => {
                let biscuit = biscuit_auth::Biscuit::from_base64(token.value(), root.public()).unwrap();
                let mut authorizer = biscuit.authorizer().unwrap();

                let sql: Vec<(String,)> = authorizer.query("sql($sql) <- sql($sql)").unwrap();

                Ok(Some(Biscuit(sql.iter().map(|t| t.clone().0).collect::<Vec<String>>().join("; "))))
            }
            _ => Ok(None)
        }
    }
}
