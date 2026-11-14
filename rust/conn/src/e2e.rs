//! TLS 1.3 inside a byte stream (a relayed stream), and the handshake facts from a QUIC connection.

use anyhow::{anyhow, Result};
use rapp_wire::tls::{e2e_client, e2e_server, peer_fp, SNI};
use rapp_wire::{Fp, Identity};
use rustls::pki_types::ServerName;
use rustls::ConnectionCommon;
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::proof::{Facts, Role, EXPORTER_LABEL};
use crate::{Pipe, Stream};

/// A direct `rapp/2` QUIC connection: `me` is our own fingerprint.
pub fn quic_facts(conn: &quinn::Connection, me: &Fp, role: Role) -> Result<Facts> {
    let mut ekm = [0u8; 32];
    conn.export_keying_material(&mut ekm, EXPORTER_LABEL, b"").map_err(|e| anyhow!("export keying material: {e:?}"))?;
    Ok(Facts { ekm, me: *me, peer: peer_fp(conn)?, role })
}

fn facts_of<D>(c: &ConnectionCommon<D>, me: &Fp, role: Role) -> Result<Facts> {
    let mut ekm = [0u8; 32];
    c.export_keying_material(&mut ekm, EXPORTER_LABEL, Some(b""))?;
    let cert = c.peer_certificates().and_then(|c| c.first()).ok_or_else(|| anyhow!("peer showed no certificate"))?;
    Ok(Facts { ekm, me: *me, peer: Fp::of_cert(cert)?, role })
}

pub async fn e2e_accept<S: Stream + 'static>(io: S, id: &Identity) -> Result<(Pipe, Facts)> {
    let tls = TlsAcceptor::from(e2e_server(id)?).accept(io).await?;
    let facts = facts_of(&**tls.get_ref().1, &id.fp, Role::Server)?;
    Ok((Box::new(tls), facts))
}

pub async fn e2e_connect<S: Stream + 'static>(io: S, id: &Identity) -> Result<(Pipe, Facts)> {
    let name = ServerName::try_from(SNI)?;
    let tls = TlsConnector::from(e2e_client(id)?).connect(name, io).await?;
    let facts = facts_of(&**tls.get_ref().1, &id.fp, Role::Client)?;
    Ok((Box::new(tls), facts))
}
