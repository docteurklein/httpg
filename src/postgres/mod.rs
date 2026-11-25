
use std::{fs, future::Future, pin::Pin, str::FromStr, sync::Arc, task::{ready, Context, Poll}, time::Duration};

use conf::Conf;
use deadpool_postgres::{Pool, Runtime};
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use tokio::{io::{AsyncRead, AsyncWrite}, task::JoinHandle};
use tokio_postgres::{AsyncMessage, CancelToken, Client, Connection, Socket, tls::{MakeTlsConnect, TlsConnect, TlsStream}};
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::{HttpgError};

struct CancelBadPlanConnection<S, T> {
    conn: Connection<S, T>,
    cancel_token: CancelToken,
}

impl<S, T> Future for CancelBadPlanConnection<S, T>
where
    S: AsyncRead + AsyncWrite + Unpin,
    T: AsyncRead + AsyncWrite + Unpin,
{
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        loop {
            match ready!(self.conn.poll_message(cx)) {
                Some(Ok(AsyncMessage::Notice(n))) => {
                    if n.message() == "supplied plan advice was not enforced" {
                        let token = self.cancel_token.clone();
                        tokio::spawn(async move {
                            let _ = token.cancel_query(tokio_postgres::NoTls).await;
                        });
                    }
                }
                Some(Ok(_)) => {}
                Some(Err(e)) => {
                    tracing::warn!(target: "deadpool.postgres", "Connection error: {e}");
                    return Poll::Ready(());
                }
                None => return Poll::Ready(()),
            }
        }
    }
}

#[derive(Clone)]
struct CancelBadPlanConnect<T> {
    tls: T,
}

impl<T> deadpool_postgres::Connect for CancelBadPlanConnect<T>
where
    T: MakeTlsConnect<Socket> + Clone + Sync + Send + 'static,
    T::Stream: Sync + Send,
    T::TlsConnect: Sync + Send,
    <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
{
    fn connect(
        &self,
        pg_config: &tokio_postgres::Config,
    ) -> Pin<Box<dyn Future<Output = Result<(Client, JoinHandle<()>), tokio_postgres::Error>> + Send + '_>> {
        let tls = self.tls.clone();
        let pg_config = pg_config.clone();
        Box::pin(async move {
            let (client, conn) = pg_config.connect(tls).await?;
            let cancel_token = client.cancel_token();
            let task = tokio::spawn(CancelBadPlanConnection { conn, cancel_token });
            Ok((client, task))
        })
    }
}

#[derive(Clone, Debug, Conf)]
pub struct PostgresConfig {
    #[conf(long="read-url", env="READ_URL", value_parser = |file: &str| -> Result<_, HttpgError> { Ok(fs::read_to_string(file).unwrap_or(file.to_string())) })]
    read_url: String,
    #[conf(long="write-url", env="WRITE_URL", value_parser = |file: &str| -> Result<_, HttpgError> { Ok(fs::read_to_string(file).unwrap_or(file.to_string())) })]
    write_url: String,
}

impl PostgresConfig {
    pub fn read_pool(&self) -> Result<Pool, HttpgError> {
        let mut cfg = deadpool_postgres::Config::new();

        cfg.url = Some(self.read_url.clone());
        self.rest(&mut cfg)
    }

    pub fn write_pool(&self) -> Result<Pool, HttpgError> {
        let mut cfg = deadpool_postgres::Config::new();

        cfg.url = Some(self.write_url.clone());
        self.rest(&mut cfg)
    }

    pub async fn connect(&self) -> Result<(Client, Connection<Socket, impl TlsStream + use<>>), HttpgError> {
        let cfg = tokio_postgres::Config::from_str(&self.write_url)?;

        let tls_config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
            .with_no_client_auth()
        ;
        cfg.connect(MakeRustlsConnect::new(tls_config)).await.map_err(Into::into)
    }

    fn rest(&self, cfg: &mut deadpool_postgres::Config) -> Result<Pool, HttpgError> {
        let tls_config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
            .with_no_client_auth()
        ;
        let tls = MakeRustlsConnect::new(tls_config);

        cfg.connect_timeout = Some(core::time::Duration::from_secs(1));

        let pg_config = cfg.get_pg_config()?;
        let manager = deadpool_postgres::Manager::from_connect(
            pg_config,
            CancelBadPlanConnect { tls },
            cfg.get_manager_config(),
        );
        let pool = deadpool_postgres::Pool::builder(manager)
            .config(cfg.get_pool_config())
            .runtime(Runtime::Tokio1)
            .build()?;

        let interval = Duration::from_secs(30);
        let max_age = Duration::from_secs(60);

        let pc = pool.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(interval).await;
                pc.retain(|_, metrics| metrics.last_used() < max_age);
            }
        });

        Ok(pool)
    }
}

pub struct QueryGuard {
    pub cancel_token: CancelToken,
    pub finished: bool,
}

impl Drop for QueryGuard {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        let cancel_token = self.cancel_token.clone();
        tokio::spawn(async move {
            let _ = cancel_token.cancel_query(tokio_postgres::NoTls).await;
        });
    }
}

#[derive(Debug)]
pub struct NoCertificateVerification {}

impl rustls::client::danger::ServerCertVerifier for NoCertificateVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ECDSA_NISTP521_SHA512,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}

