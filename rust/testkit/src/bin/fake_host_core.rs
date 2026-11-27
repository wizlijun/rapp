//! host-core as a program (plan B, Task 19): `rapp_host_core::run` on the fake platform and the
//! real clock, with this process's own arguments, environment and standard streams. Tests link it
//! under the name `rapp-host` into a service's bin dir, so the real `rapp-service` starts it as its
//! worker and speaks the worker CLI (`list-apps --json`, `serve ... --json`, stdin commands) to it.

use std::io::BufReader;
use std::sync::Arc;

use rapp_host_core::clock::SystemClock;
use rapp_host_core::run::{run, WorkerIo};
use rapp_testkit::fake_platform::FakePlatform;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let env = |key: &str| std::env::var(key).ok();
    let io = WorkerIo {
        stdin: Box::new(BufReader::new(std::io::stdin())),
        stdout: Box::new(std::io::stdout()),
        stderr: Box::new(std::io::stderr()),
    };
    let code = run(&args, &env, Arc::new(FakePlatform::new()), io, Arc::new(SystemClock));
    std::process::exit(code);
}
