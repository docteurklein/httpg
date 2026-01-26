
use std::{fs, sync::Arc};

use conf::Conf;
use deadpool_postgres::{Pool, Runtime};
use rustls::{client::danger::{HandshakeSignatureValid, ServerCertVerified}, pki_types::{CertificateDer, ServerName, UnixTime}};
use tokio_postgres::{Client, Connection, Socket, tls::TlsStream};
use tokio_postgres_rustls::MakeRustlsConnect;

use crate::{HttpgError};

#[derive(Clone, Debug, Conf)]
#[conf(env_prefix="PG_")]
pub struct PostgresConfig {
    #[conf(env)]
    read_host: String,
    #[conf(env)]
    write_host: String,
    #[conf(env)]
    user: String,
    #[conf(env, value_parser = |file: &str| -> Result<_, HttpgError> { Ok(fs::read_to_string(file)?) })]
    password: String,
    #[conf(env)]
    dbname: String,
    #[conf(env)]
    channel_binding: Option<String>,
    #[conf(env)]
    ssl_mode: Option<String>,
}

impl PostgresConfig {
    pub fn read_pool(&self) -> Result<Pool, HttpgError> {
        let mut cfg = deadpool_postgres::Config::new();

        cfg.host = Some(self.read_host.clone());
        self.rest(&mut cfg)
    }

    pub async fn connect(&self) -> Result<(Client, Connection<Socket, impl TlsStream>), HttpgError> {
        let cfg = tokio_postgres::Config::new()
            .user(self.user.clone())
            .password(self.password.clone())
            .dbname(self.dbname.clone())
            .host(self.write_host.clone())
            .ssl_mode(match self.ssl_mode.as_deref() {
                Some("require") => tokio_postgres::config::SslMode::Require,
                _ => tokio_postgres::config::SslMode::Prefer,
            })
            .channel_binding(match self.channel_binding.as_deref() {
                Some("require") => tokio_postgres::config::ChannelBinding::Require,
                _ => tokio_postgres::config::ChannelBinding::Prefer,
            })
            .to_owned()
        ;

        let tls_config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
            .with_no_client_auth()
        ;

        cfg.connect(MakeRustlsConnect::new(tls_config)).await.map_err(Into::into)
    }

    pub fn write_pool(&self) -> Result<Pool, HttpgError> {
        let mut cfg = deadpool_postgres::Config::new();

        cfg.host = Some(self.write_host.clone());
        self.rest(&mut cfg)
    }

    fn rest(&self, cfg: &mut deadpool_postgres::Config) -> Result<Pool, HttpgError> {
        cfg.user = Some(self.user.clone());
        cfg.password = Some(self.password.clone());
        cfg.dbname = Some(self.dbname.clone());
        cfg.ssl_mode = Some(match self.ssl_mode.as_deref() {
            Some("require") => deadpool_postgres::SslMode::Require,
            _ => deadpool_postgres::SslMode::Prefer,
        });
        cfg.channel_binding = Some(match self.channel_binding.as_deref() {
            Some("require") => deadpool_postgres::ChannelBinding::Require,
            _ => deadpool_postgres::ChannelBinding::Prefer,
        });

        let tls_config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoCertificateVerification {}))
            .with_no_client_auth()
        ;
        let tls = MakeRustlsConnect::new(tls_config);

        cfg.create_pool(Some(Runtime::Tokio1), tls).map_err(Into::into)
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

