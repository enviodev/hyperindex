use std::future::Future;
use std::io;
use std::path::Path;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use anyhow::{Context as _, Result};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio_postgres::tls::{ChannelBinding, MakeTlsConnect, TlsConnect};
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;

/// TLS for the pool, on rustls.
///
/// A verifying connection trusts what Node does — the Mozilla roots and
/// `NODE_EXTRA_CA_CERTS` — and the operating system's store besides, so a CA an
/// operator installed the usual way is trusted too. Nothing here depends on
/// where a C library was told to look at build time.
#[derive(Clone)]
pub struct MakeRustlsConnect {
    config: Arc<ClientConfig>,
}

impl MakeRustlsConnect {
    /// `extra_ca_file` is where `NODE_EXTRA_CA_CERTS` points, passed in rather
    /// than read here so a test can name its own CA.
    pub fn new(verify: bool, extra_ca_file: Option<&Path>) -> Result<Self> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let builder = ClientConfig::builder_with_provider(provider.clone())
            .with_safe_default_protocol_versions()
            .context("Failed preparing the TLS configuration")?;
        let config = if verify {
            builder.with_root_certificates(trusted_roots(extra_ca_file)?)
        } else {
            builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(AcceptAnyCertificate(provider)))
        }
        .with_no_client_auth();
        Ok(Self {
            config: Arc::new(config),
        })
    }
}

fn trusted_roots(extra_ca_file: Option<&Path>) -> Result<RootCertStore> {
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    // A store that is missing or partly unreadable still leaves the Mozilla
    // roots to verify against, which is all a slim container image has.
    roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
    if let Some(path) = extra_ca_file {
        let pem = std::fs::read(path)
            .with_context(|| format!("Failed reading NODE_EXTRA_CA_CERTS at {}", path.display()))?;
        let certs = CertificateDer::pem_slice_iter(&pem)
            .collect::<Result<Vec<_>, _>>()
            .with_context(|| format!("Failed parsing NODE_EXTRA_CA_CERTS at {}", path.display()))?;
        roots.add_parsable_certificates(certs);
    }
    Ok(roots)
}

/// What `require`, `allow` and `prefer` mean: encrypted, but whoever answers is
/// taken at their word. The handshake's own signatures are still checked, so
/// the connection is at least with the holder of the certificate presented.
#[derive(Debug)]
struct AcceptAnyCertificate(Arc<CryptoProvider>);

impl ServerCertVerifier for AcceptAnyCertificate {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

impl<S> MakeTlsConnect<S> for MakeRustlsConnect
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    type Stream = RustlsStream<S>;
    type TlsConnect = RustlsConnect;
    type Error = io::Error;

    fn make_tls_connect(&mut self, domain: &str) -> io::Result<RustlsConnect> {
        let server_name = ServerName::try_from(domain.to_string())
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        Ok(RustlsConnect {
            connector: TlsConnector::from(self.config.clone()),
            server_name,
        })
    }
}

pub struct RustlsConnect {
    connector: TlsConnector,
    server_name: ServerName<'static>,
}

impl<S> TlsConnect<S> for RustlsConnect
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    type Stream = RustlsStream<S>;
    type Error = io::Error;
    type Future = Pin<Box<dyn Future<Output = io::Result<RustlsStream<S>>> + Send>>;

    fn connect(self, stream: S) -> Self::Future {
        Box::pin(async move {
            self.connector
                .connect(self.server_name, stream)
                .await
                .map(RustlsStream)
        })
    }
}

pub struct RustlsStream<S>(TlsStream<S>);

impl<S> tokio_postgres::tls::TlsStream for RustlsStream<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    fn channel_binding(&self) -> ChannelBinding {
        ChannelBinding::none()
    }
}

impl<S> AsyncRead for RustlsStream<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_read(cx, buf)
    }
}

impl<S> AsyncWrite for RustlsStream<S>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.0).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.0).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair};
    use rustls::pki_types::PrivatePkcs8KeyDer;
    use rustls::ServerConfig;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;
    use tokio_rustls::TlsAcceptor;

    use super::*;
    use crate::postgres::client::{PgClient, PgConnectionOptions, SslSetting};
    use crate::postgres::error::message_of;

    const SSL_REQUEST: i32 = 80877103;

    /// A server that answers a connection's TLS request and then refuses its
    /// startup with a message saying whether the connection was encrypted —
    /// enough of Postgres to see what each SSL mode does on a handshake.
    struct FakeServer {
        port: u16,
        accepting: tokio::task::JoinHandle<()>,
    }

    impl FakeServer {
        async fn start(tls: Option<TlsAcceptor>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let accepting = tokio::spawn(async move {
                while let Ok((socket, _)) = listener.accept().await {
                    let tls = tls.clone();
                    tokio::spawn(async move {
                        let _ = answer(socket, tls).await;
                    });
                }
            });
            Self { port, accepting }
        }
    }

    impl Drop for FakeServer {
        fn drop(&mut self) {
            self.accepting.abort();
        }
    }

    async fn answer(mut socket: tokio::net::TcpStream, tls: Option<TlsAcceptor>) -> io::Result<()> {
        if read_message(&mut socket).await? != SSL_REQUEST {
            return refuse(&mut socket, "plaintext").await;
        }
        match tls {
            Some(acceptor) => {
                socket.write_all(b"S").await?;
                let mut stream = acceptor.accept(socket).await?;
                read_message(&mut stream).await?;
                refuse(&mut stream, "encrypted").await
            }
            None => {
                socket.write_all(b"N").await?;
                read_message(&mut socket).await?;
                refuse(&mut socket, "plaintext").await
            }
        }
    }

    /// A startup-phase message: its length, then a code saying what it is.
    async fn read_message<S: AsyncRead + Unpin>(stream: &mut S) -> io::Result<i32> {
        let length = stream.read_i32().await?;
        let mut rest = vec![0; usize::try_from(length - 4).unwrap_or(0)];
        stream.read_exact(&mut rest).await?;
        Ok(i32::from_be_bytes(rest[..4].try_into().unwrap_or_default()))
    }

    async fn refuse<S: AsyncWrite + Unpin>(stream: &mut S, message: &str) -> io::Result<()> {
        let mut fields = Vec::new();
        for (code, value) in [
            (b'S', "FATAL"),
            (b'V', "FATAL"),
            (b'C', "28000"),
            (b'M', message),
        ] {
            fields.push(code);
            fields.extend_from_slice(value.as_bytes());
            fields.push(0);
        }
        fields.push(0);
        let mut response = vec![b'E'];
        response.extend_from_slice(&i32::try_from(fields.len() + 4).unwrap().to_be_bytes());
        response.extend_from_slice(&fields);
        stream.write_all(&response).await?;
        stream.flush().await
    }

    /// A CA of the test's own, and a certificate it signed naming `localhost`
    /// and nothing else.
    fn certificates() -> (String, TlsAcceptor) {
        let ca_key = KeyPair::generate().unwrap();
        let mut ca_params = CertificateParams::new(Vec::<String>::new()).unwrap();
        ca_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
        let ca_pem = ca_params.self_signed(&ca_key).unwrap().pem();
        let issuer = Issuer::new(ca_params, ca_key);

        let server_key = KeyPair::generate().unwrap();
        let server_cert = CertificateParams::new(vec!["localhost".to_string()])
            .unwrap()
            .signed_by(&server_key, &issuer)
            .unwrap();
        let config =
            ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(
                    vec![server_cert.der().clone()],
                    PrivatePkcs8KeyDer::from(server_key.serialize_der()).into(),
                )
                .unwrap();
        (ca_pem, TlsAcceptor::from(Arc::new(config)))
    }

    /// What a connection in this mode makes of the server: the message the
    /// server refused it with, or why it never got that far.
    async fn outcome(
        server: &FakeServer,
        ssl: SslSetting,
        host: &str,
        extra_ca_file: Option<&Path>,
    ) -> String {
        let client = PgClient::connect(PgConnectionOptions {
            host: host.to_string(),
            port: server.port,
            user: "postgres".to_string(),
            password: "unused".to_string(),
            database: "unused".to_string(),
            ssl,
            max_connections: 1,
            application_name: None,
            extra_ca_file: extra_ca_file.map(Path::to_path_buf),
            connect_timeout: std::time::Duration::from_secs(5),
        })
        .unwrap();
        match client.query("SELECT 1", &[]).await {
            Ok(_) => "answered".to_string(),
            Err(error) => message_of(&error),
        }
    }

    /// The certificate is signed by a CA nothing trusts until it is named as
    /// `NODE_EXTRA_CA_CERTS` would name it, and it names `localhost` only, so
    /// the same server reached as 127.0.0.1 is what separates a mode that
    /// verifies from one that only encrypts.
    #[tokio::test]
    async fn each_ssl_mode_connects_the_way_it_says() {
        let (ca_pem, acceptor) = certificates();
        let dir = tempdir::TempDir::new("envio-tls").unwrap();
        let ca_file = dir.path().join("ca.pem");
        std::fs::write(&ca_file, ca_pem).unwrap();
        let tls = FakeServer::start(Some(acceptor)).await;
        let plain = FakeServer::start(None).await;
        let ca = Some(ca_file.as_path());

        assert_eq!(
            [
                outcome(&tls, SslSetting::Verify, "localhost", ca).await,
                outcome(&tls, SslSetting::Verify, "localhost", None).await,
                outcome(&tls, SslSetting::Verify, "127.0.0.1", ca).await,
                outcome(&tls, SslSetting::NoVerify, "127.0.0.1", None).await,
                outcome(&tls, SslSetting::PreferNoVerify, "localhost", None).await,
                outcome(&tls, SslSetting::Disable, "localhost", None).await,
                outcome(&plain, SslSetting::PreferNoVerify, "localhost", None).await,
                outcome(&plain, SslSetting::NoVerify, "localhost", None).await,
            ],
            [
                "encrypted",
                "Failed taking a Postgres connection from the pool: Error occurred while \
                 creating a new object: error performing TLS handshake: invalid peer \
                 certificate: UnknownIssuer",
                "Failed taking a Postgres connection from the pool: Error occurred while \
                 creating a new object: error performing TLS handshake: invalid peer \
                 certificate: certificate not valid for name \"127.0.0.1\"; certificate is \
                 only valid for DnsName(\"localhost\")",
                "encrypted",
                "encrypted",
                "plaintext",
                "plaintext",
                "Failed taking a Postgres connection from the pool: Error occurred while \
                 creating a new object: error performing TLS handshake: server does not \
                 support TLS",
            ]
            .map(String::from)
        );
    }
}
