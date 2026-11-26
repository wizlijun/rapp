//! The real `rapp-state` service, built inside the testkit: the integration tests link it under
//! the name `rapp-state` into a service's bin dir, so `rapp-service` starts it as its companion.

#[tokio::main]
async fn main() {
    std::process::exit(rapp_state::cli(std::env::args().skip(1).collect()).await)
}
