
use axum::{
    extract::{FromRef, OptionalFromRequestParts}, http::request::Parts,
};
use axum_extra::extract::CookieJar;
use biscuit_auth::{KeyPair, PrivateKey};

use crate::{AppState, HttpgError};

pub struct Biscuit(pub String);

impl<S> OptionalFromRequestParts<S> for Biscuit
where
    AppState: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = HttpgError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Option<Self>, Self::Rejection> {
        let state = AppState::from_ref(state);
        let root = KeyPair::from(&PrivateKey::from_bytes(&state.config.private_key)?);
        let cookies = CookieJar::from_headers(&parts.headers);
        match cookies.get("auth") {
            Some(token) => {
                let biscuit = biscuit_auth::Biscuit::from_base64(token.value(), root.public())?;
                let mut authorizer = biscuit.authorizer()?;

                let sql: Vec<(String,)> = authorizer.query("sql($sql) <- sql($sql)")?;

                Ok(Some(Biscuit(sql.iter().map(|t| t.clone().0).collect::<Vec<String>>().join("; "))))
            }
            _ => Ok(None)
        }
    }
}
