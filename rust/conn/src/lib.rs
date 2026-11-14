//! Device-to-device connections: end-to-end TLS over any byte stream, the key-trust proof
//! bound to the TLS handshake, the hello exchange and the list of paired devices.

pub mod e2e;
pub mod hello;
pub mod paired;
pub mod proof;
pub mod relay;
pub mod settings;

use tokio::io::{AsyncRead, AsyncWrite};

pub use e2e::{e2e_accept, e2e_connect, quic_facts};
pub use hello::{hello_server, read_welcome, send_hello, Accepted, Greeted, Me};
pub use paired::Paired;
pub use proof::{check, proof, Facts, Role};

pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

pub type Pipe = Box<dyn Stream>;
