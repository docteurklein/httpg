
use std::sync::Arc;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio_postgres::{NoTls, tls::{MakeTlsConnect, NoTlsStream, TlsConnect, TlsStream}};
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::{HttpgError, NoCertificateVerification};

pub enum Conn {
    NoTls,
    Tls
}

impl<S> MakeTlsConnect<S> for Conn
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + Sync + 'static,
{
    type Stream: TlsStream;
    type TlsConnect: TlsConnect<S, Stream = Self::Stream>;
    type Error = HttpgError;

    fn make_tls_connect(&mut self, domain: &str) -> Result<Self::TlsConnect, Self::Error>
    {
        match self {
            Conn::Tls => {
                let tls_config = rustls::ClientConfig::builder()
                    .dangerous()
                    .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
                    .with_no_client_auth()
                ;
                MakeRustlsConnect::new(tls_config).make_tls_connect("*")
            },
            Conn::NoTls => NoTls.make_tls_connect("*"),
        }
    }
}
