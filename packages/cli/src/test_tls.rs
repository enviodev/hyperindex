use std::sync::Arc;

use rcgen::{BasicConstraints, CertificateParams, IsCa, Issuer, KeyPair};
use rustls::pki_types::PrivatePkcs8KeyDer;
use rustls::ServerConfig;

/// A CA of the test's own as PEM, and a server config whose certificate it
/// signed, naming `localhost` and nothing else.
pub(crate) fn localhost_server_config() -> (String, ServerConfig) {
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
    (ca_pem, config)
}
