use std::convert::Infallible;

use http_body_util::Full;
use hyper::body::{Bytes, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use tokio::net::TcpListener;

use crate::Config;

fn reply(status: StatusCode, body: Value) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(body.to_string())))
        .expect("static response parts are valid")
}

async fn route(_cfg: &Config, req: Request<Incoming>) -> Response<Full<Bytes>> {
    match (req.method(), req.uri().path()) {
        (&Method::GET, "/v1/health") => reply(StatusCode::OK, json!({"name": "rapp-state", "v": 1})),
        _ => reply(StatusCode::NOT_FOUND, json!({"error": "not found"})),
    }
}

pub async fn serve(cfg: Config, listener: TcpListener) -> anyhow::Result<()> {
    let cfg = std::sync::Arc::new(cfg);
    loop {
        let (stream, _) = listener.accept().await?;
        let cfg = cfg.clone();
        tokio::spawn(async move {
            let svc = service_fn(move |req| {
                let cfg = cfg.clone();
                async move { Ok::<_, Infallible>(route(&cfg, req).await) }
            });
            let _ = http1::Builder::new().serve_connection(TokioIo::new(stream), svc).await;
        });
    }
}
