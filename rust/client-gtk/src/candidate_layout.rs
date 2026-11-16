//! One row, local pages. Positions never replace the input engine's indices.
#[derive(Debug, Default, PartialEq)]
pub struct Page {
    pub start: usize,
    pub end: usize,
    pub widths: Vec<f64>,
}

pub fn page(widths: &[f64], available: f64, gap: f64, selected: usize) -> Page {
    if widths.is_empty() || !available.is_finite() || available <= 0. {
        return Page::default();
    }
    let selected = selected.min(widths.len() - 1);
    let mut result = Page::default();
    let mut used = 0.;
    for (i, width) in widths.iter().enumerate() {
        let width = width.max(1.).min(available);
        let extra = if result.widths.is_empty() {
            0.
        } else {
            gap.max(0.)
        };
        if !result.widths.is_empty() && used + extra + width > available {
            result.end = i;
            if selected < i {
                return result;
            }
            result = Page {
                start: i,
                ..Page::default()
            };
            used = 0.;
        }
        if !result.widths.is_empty() {
            used += gap.max(0.);
        }
        result.widths.push(width);
        used += width;
    }
    result.end = widths.len();
    result
}

#[derive(Default)]
pub struct Epoch {
    pub generation: u64,
    pub serial: u64,
    pub active: bool,
    pub accepted: bool,
}
impl Epoch {
    pub fn reset(&mut self, active: bool) -> u64 {
        self.generation += 1;
        self.serial = 0;
        self.active = active;
        self.accepted = false;
        self.generation
    }
    pub fn current(&self, generation: u64) -> bool {
        self.active && self.generation == generation
    }
    pub fn frame(&mut self, generation: u64, serial: u64) -> bool {
        if !self.current(generation) || serial <= self.serial {
            return false;
        }
        self.serial = serial;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn one_row_pages_keep_every_position_and_selected_page() {
        assert_eq!(
            page(&[30., 40., 70., 10.], 80., 5., 0),
            Page {
                start: 0,
                end: 2,
                widths: vec![30., 40.]
            }
        );
        assert_eq!(
            page(&[30., 40., 70., 10.], 80., 5., 2),
            Page {
                start: 2,
                end: 3,
                widths: vec![70.]
            }
        );
        assert_eq!(page(&[500., 20.], 60., 5., 0).widths, [60.]);
        assert_eq!(page(&[500., 20.], 60., 5., 1).start, 1);
        assert_eq!(page(&[], 0., 0., 0), Page::default());
    }
    #[test]
    fn revoked_and_replaced_leases_reject_delayed_replies_and_frames() {
        let mut state = Epoch::default();
        let old = state.reset(true);
        assert!(state.frame(old, 1));
        assert!(!state.frame(old, 1));
        state.reset(false);
        assert!(!state.current(old));
        let fresh = state.reset(true);
        assert!(!state.frame(old, 9));
        assert!(state.frame(fresh, 1));
        assert!(!state.accepted);
    }
}
