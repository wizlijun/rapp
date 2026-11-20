//! One capture/encode job at a time, independent of the input/control loop.
use crate::{
    desktop::{Desktop, Display},
    encode::Encoder,
    wire::Settings,
};
use anyhow::{ensure, Result};
use rapp_client_core::protocol::Rect;
use std::{
    sync::mpsc,
    time::{Duration, Instant},
};

pub struct Job {
    pub epoch: u64,
    pub settings: Settings,
    pub view: Option<(u32, Rect)>,
}
pub struct Completed {
    pub epoch: u64,
    pub elapsed: Duration,
    pub frame: Result<Option<Vec<u8>>>,
}
pub struct CaptureWorker {
    jobs: mpsc::SyncSender<Job>,
    results: mpsc::Receiver<Completed>,
    busy: bool,
}
impl CaptureWorker {
    pub fn start(app: String, expected: Display) -> Self {
        let (jobs, incoming) = mpsc::sync_channel::<Job>(1);
        let (finished, results) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let mut desktop: Option<Desktop> = None;
            let mut encoder = Encoder::default();
            let mut epoch = None;
            while let Ok(job) = incoming.recv() {
                let began = Instant::now();
                let frame = (|| {
                    if desktop.is_none() {
                        let mut d = Desktop::connect()?;
                        let selected = d.select_capture(&app)?;
                        ensure!(
                            selected.id == expected.id
                                && selected.width == expected.width
                                && selected.height == expected.height
                                && selected.x == expected.x
                                && selected.y == expected.y,
                            "display changed; reconnect to refresh the desktop"
                        );
                        desktop = Some(d);
                    }
                    if epoch != Some(job.epoch) {
                        // Discarded results must never become the reference for
                        // another client or a changed mode/density.
                        encoder.reset();
                        epoch = Some(job.epoch);
                    }
                    let desktop = desktop.as_mut().unwrap();
                    let view = desktop.view_region(job.view)?;
                    let (image, region) = if let Some(view) = view {
                        let (image, region) = desktop.capture()?.cropped(&expected, view);
                        (image.scaled_region(region, job.settings.density), region)
                    } else {
                        (
                            desktop.capture_scaled(&expected, job.settings.density)?,
                            Rect {
                                x: 0.,
                                y: 0.,
                                w: expected.width as f32,
                                h: expected.height as f32,
                            },
                        )
                    };
                    encoder.frame_region(
                        &image.pixels,
                        image.width,
                        image.height,
                        region,
                        job.settings.mode,
                    )
                })();
                if frame.is_err() {
                    desktop = None;
                    epoch = None;
                }
                if finished
                    .send(Completed {
                        epoch: job.epoch,
                        elapsed: began.elapsed(),
                        frame,
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            jobs,
            results,
            busy: false,
        }
    }
    pub fn submit(&mut self, job: Job) -> Result<bool> {
        if self.busy {
            return Ok(false);
        }
        self.jobs.send(job)?;
        self.busy = true;
        Ok(true)
    }
    pub fn completed(&mut self) -> Option<Completed> {
        let result = self.results.try_recv().ok()?;
        self.busy = false;
        Some(result)
    }
}

/// Leave compositor/CPU time for the local desktop when readback is expensive.
/// Static desktops back off; a remote input wakes the next capture immediately.
pub fn rest(fps: u8, work: Duration, unchanged: u32) -> Duration {
    let period = Duration::from_secs_f64(1. / fps as f64);
    let paced = period.saturating_sub(work).max(work);
    if unchanged >= 8 {
        paced.max(Duration::from_millis(250))
    } else if unchanged > 0 {
        paced.max(Duration::from_millis(100))
    } else {
        paced
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pacing_respects_requested_rate_but_leaves_room_for_the_desktop() {
        let fast = Duration::from_millis(5);
        assert_eq!(rest(30, fast, 0) + fast, Duration::from_secs_f64(1. / 30.));
        assert_eq!(
            rest(30, Duration::from_millis(80), 0),
            Duration::from_millis(80)
        );
        assert!(rest(15, fast, 8) >= Duration::from_millis(250));
        assert!(rest(1, fast, 8) >= Duration::from_millis(995));
    }
}
