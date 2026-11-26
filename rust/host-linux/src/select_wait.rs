//! Helpers for `select_input` on the Linux host: queue the command instead of failing when the
//! helper thread is busy, then wait (bounded) for the switch to finish so the next keys land in
//! the new input source. Shared so tests run everywhere; only the Linux input source uses it.
use anyhow::{anyhow, Result};
use std::{
    sync::mpsc::{self, TrySendError},
    time::{Duration, Instant},
};

/// `try_send` that retries every 10 ms while the queue is full, up to `max`.
pub(crate) fn send_queued<T>(tx: &mpsc::SyncSender<T>, value: T, max: Duration) -> Result<()> {
    let deadline = Instant::now() + max;
    let mut value = value;
    loop {
        match tx.try_send(value) {
            Ok(()) => return Ok(()),
            Err(TrySendError::Disconnected(_)) => {
                return Err(anyhow!("input source helper stopped"))
            }
            Err(TrySendError::Full(v)) => {
                if Instant::now() >= deadline {
                    return Err(anyhow!("input source helper busy"));
                }
                value = v;
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

/// Wait up to `max` for the done signal (a dropped sender counts as done), then sleep `settle`.
pub(crate) fn wait_done(done: &mpsc::Receiver<()>, max: Duration, settle: Duration) {
    let _ = done.recv_timeout(max);
    std::thread::sleep(settle);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        sync::mpsc,
        time::{Duration, Instant},
    };

    #[test]
    fn waits_for_the_switch_then_settles() {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            let _ = tx.send(());
        });
        let t = Instant::now();
        wait_done(&rx, Duration::from_millis(300), Duration::from_millis(50));
        let e = t.elapsed();
        assert!(
            e >= Duration::from_millis(150) && e < Duration::from_millis(300),
            "{e:?}"
        );
    }
    #[test]
    fn a_hung_switch_costs_at_most_max_plus_settle() {
        let (_tx, rx) = mpsc::channel::<()>();
        let t = Instant::now();
        wait_done(&rx, Duration::from_millis(300), Duration::from_millis(50));
        let e = t.elapsed();
        assert!(
            e >= Duration::from_millis(350) && e < Duration::from_millis(500),
            "{e:?}"
        );
    }
    #[test]
    fn a_full_queue_waits_instead_of_failing() {
        let (tx, rx) = mpsc::sync_channel::<u8>(1);
        tx.try_send(0).unwrap();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            let _ = rx.recv();
            std::thread::sleep(Duration::from_secs(1));
        });
        assert!(send_queued(&tx, 1, Duration::from_millis(300)).is_ok());
    }
    #[test]
    fn a_queue_full_past_max_is_busy() {
        let (tx, _rx) = mpsc::sync_channel::<u8>(1);
        tx.try_send(0).unwrap();
        let err = send_queued(&tx, 1, Duration::from_millis(30)).unwrap_err();
        assert!(err.to_string().contains("busy"));
    }
    #[test]
    fn a_dropped_receiver_errors_at_once() {
        let (tx, rx) = mpsc::sync_channel::<u8>(1);
        drop(rx);
        let t = Instant::now();
        assert!(send_queued(&tx, 1, Duration::from_secs(5)).is_err());
        assert!(t.elapsed() < Duration::from_millis(100));
    }
}
