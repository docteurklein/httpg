
use std::{env, fs, sync::Arc};

use conf::Conf;
use deadpool_postgres::{Pool, Runtime};
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use serde::{Deserialize, Serialize};
use tokio_postgres::{Client, Connection, Socket, tls::TlsStream};
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::{HttpgError};

#[derive(Clone, Debug, Conf)]
#[conf(env_prefix="PG_")]
pub struct PostgresConfig {
    #[conf(env)]
    host: String,
    #[conf(env)]
    user: String,
    #[conf(env, value_parser = |file: &str| -> Result<_, HttpgError> { Ok(fs::read_to_string(file)?) })]
    password: String,
    #[conf(env)]
    dbname: String,
}

#[derive(Clone, Debug)]
pub struct PostgresConn(tokio_postgres::Config);

impl PostgresConn {
    pub fn from_env() -> Self {// tokio_postgres::Config {
        let cfg = PostgresConfig::parse();
        Self(tokio_postgres::Config::new()
            .user(cfg.user)
            .password(cfg.password)
            .dbname(cfg.dbname)
            .host(cfg.host)
            .ssl_mode(match env::var("PG_SSLMODE").as_deref() {
                Ok("require") => tokio_postgres::config::SslMode::Require,
                _ => tokio_postgres::config::SslMode::Prefer,
            })
            .to_owned()
        )
    }

    pub async fn connect(&mut self) -> Result<(Client, Connection<Socket, impl TlsStream>), HttpgError> {
        let tls_config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
            .with_no_client_auth()
        ;

        self.0.connect(MakeRustlsConnect::new(tls_config)).await.map_err(Into::into)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct DeadPoolConfig {
    #[serde(default)]
    pg: deadpool_postgres::Config,
}

impl DeadPoolConfig {
    pub fn read() -> Result<Self, config::ConfigError> {
        let config = config::Config::builder()
            .add_source(config::Environment::default()
                .prefix("PG")
                .separator("_")
                .keep_prefix(true)
            )
            .add_source(config::Environment::default()
                .prefix("PG_READ")
                .separator("_")
                .keep_prefix(false)
            )
            .build()?
        ;

        config.try_deserialize::<Self>()
    }

    pub fn write() -> Result<Self, config::ConfigError> {
        let config = config::Config::builder()
            .add_source(config::Environment::default()
                .prefix("PG")
                .separator("_")
                .keep_prefix(true)
            )
            .add_source(config::Environment::default()
                .prefix("PG_WRITE")
                .separator("_")
                .keep_prefix(false)
            )
            .build()?
        ;

        config.try_deserialize::<Self>()
    }

    pub fn create_pool(&mut self) -> Result<Pool, HttpgError> {
        let tls_config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
            .with_no_client_auth()
        ;
        let tls = MakeRustlsConnect::new(tls_config);

        self.pg.create_pool(Some(Runtime::Tokio1), tls).map_err(Into::into)
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

