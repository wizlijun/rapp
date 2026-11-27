//! The real `rapp-center` service, built inside the testkit: the integration tests link it under
//! the name `rapp-center` into a service's bin dir, so `rapp-service` starts it as its companion.

#[tokio::main]
async fn main() {
    std::process::exit(rapp_center::cli(std::env::args().skip(1).collect()).await)
}
