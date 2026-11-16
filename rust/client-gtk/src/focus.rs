//! Native rendering of the same focus panes as Flutter: gray outside, colour inside.
use gtk::cairo;
use rapp_client_core::protocol::{Rect, Window};
use std::collections::HashMap;

pub fn grayscale(surface: &cairo::ImageSurface) -> Option<cairo::ImageSurface> {
    let mut bytes = Vec::new();
    surface.with_data(|data| bytes.extend_from_slice(data)).ok()?;
    for pixel in bytes.chunks_exact_mut(4) {
        let luma = ((77 * pixel[2] as u32 + 150 * pixel[1] as u32 + 29 * pixel[0] as u32) / 256) as u8;
        pixel[..3].fill(luma);
    }
    cairo::ImageSurface::create_for_data(
        bytes,
        cairo::Format::Rgb24,
        surface.width(),
        surface.height(),
        surface.stride(),
    )
    .ok()
}

/// Coordinates here are decoded-canvas pixels. The caller clips/scales to its own window.
pub fn paint(
    cr: &cairo::Context,
    colour: &cairo::ImageSurface,
    gray: Option<&cairo::ImageSurface>,
    region: Rect,
    windows: &[Window],
    panes: &HashMap<u32, Vec<Rect>>,
) {
    if cr.set_source_surface(colour, 0., 0.).is_err() {
        return;
    }
    let _ = cr.paint();
    let Some(gray) = gray else { return };
    if region.w <= 0. || region.h <= 0. {
        return;
    }
    let sx = colour.width() as f64 / region.w as f64;
    let sy = colour.height() as f64 / region.h as f64;
    // Back to front: a parent's focus mask must not cover an overlapping popup.
    for w in windows.iter().rev() {
        let _ = cr.save();
        cr.rectangle(
            (w.rect.x - region.x) as f64 * sx,
            (w.rect.y + w.title_bar - region.y) as f64 * sy,
            w.rect.w as f64 * sx,
            (w.rect.h - w.title_bar) as f64 * sy,
        );
        cr.clip();
        let rects = panes.get(&w.id).filter(|r| !r.is_empty());
        let _ = cr.set_source_surface(if rects.is_some() { gray } else { colour }, 0., 0.);
        let _ = cr.paint();
        if let Some(rects) = rects {
            let _ = cr.save();
            // Non-zero winding gives the union, including overlapping panes.
            for r in rects {
                cr.rectangle(
                    (w.rect.x + r.x - region.x) as f64 * sx,
                    (w.rect.y + r.y - region.y) as f64 * sy,
                    r.w as f64 * sx,
                    r.h as f64 * sy,
                );
            }
            cr.clip();
            let _ = cr.set_source_surface(colour, 0., 0.);
            let _ = cr.paint();
            let _ = cr.restore();
            // Matches main's temporary focus debug frames.
            cr.set_source_rgb(0., 200. / 255., 83. / 255.);
            cr.set_line_width(2. * sx.min(sy));
            for r in rects {
                cr.rectangle(
                    (w.rect.x + r.x - region.x) as f64 * sx + sx,
                    (w.rect.y + r.y - region.y) as f64 * sy + sy,
                    (r.w as f64 - 2.).max(0.) * sx,
                    (r.h as f64 - 2.).max(0.) * sy,
                );
                let _ = cr.stroke();
            }
        }
        let _ = cr.restore();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pixel(s: &cairo::ImageSurface, x: usize, y: usize) -> Vec<u8> {
        let mut out = Vec::new();
        s.with_data(|data| out.extend_from_slice(&data[y * s.stride() as usize + x * 4..][..3])).unwrap();
        out
    }
    #[test]
    fn overlapping_panes_stay_colour_and_popup_keeps_its_own_colour() {
        let source = cairo::ImageSurface::create_for_data(
            [0u8, 0, 255, 255].repeat(100 * 100),
            cairo::Format::Rgb24,
            100,
            100,
            400,
        )
        .unwrap();
        let gray = grayscale(&source).unwrap();
        let target = cairo::ImageSurface::create(cairo::Format::Rgb24, 100, 100).unwrap();
        let cr = cairo::Context::new(&target).unwrap();
        let region = Rect { x: 100., y: 200., w: 100., h: 100. };
        let parent = Window { id: 1, parent: 0, kind: 0, flags: 3, rect: region, title_bar: 0., title: String::new() };
        let popup = Window {
            id: 2,
            parent: 1,
            kind: 3,
            flags: 0,
            rect: Rect { x: 180., y: 280., w: 20., h: 20. },
            title_bar: 0.,
            title: String::new(),
        };
        let panes = HashMap::from([(
            1,
            vec![Rect { x: 10., y: 10., w: 40., h: 40. }, Rect { x: 30., y: 30., w: 40., h: 40. }],
        )]);
        paint(&cr, &source, Some(&gray), region, &[popup, parent], &panes);
        assert_eq!(pixel(&target, 5, 5), vec![76, 76, 76]);
        assert_eq!(pixel(&target, 40, 40), vec![0, 0, 255]);
        assert_eq!(pixel(&target, 90, 90), vec![0, 0, 255]);
    }
}
