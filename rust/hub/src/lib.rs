use std::path::PathBuf;
use tokio::io::{AsyncRead, AsyncWrite};

pub struct Opts {
    pub home: PathBuf,
    pub bin_dir: Option<PathBuf>,
    pub force_path: Option<String>,
}

pub async fn run<R, W>(_opts: Opts, _input: R, _output: W) -> anyhow::Result<()>
where
    R: AsyncRead + Unpin + Send + 'static,
    W: AsyncWrite + Unpin + Send + 'static,
{
    unimplemented!()
}
