//! Taskbar icon sizes. 100% DPI uses 16px; 125% uses 20; 150% uses 24; 200% uses 32.

/// Smallest shipped size that is at least the system small-icon metric.
/// Larger metrics stay at 32 instead of scaling a 16px bitmap up.
pub fn snap_tray_icon_px(system_small: i32) -> i32 {
    const SIZES: [i32; 4] = [16, 20, 24, 32];
    let want = if system_small <= 0 { 16 } else { system_small };
    SIZES.into_iter().find(|size| *size >= want).unwrap_or(32)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snaps_to_the_dpi_sizes_the_taskbar_asks_for() {
        assert_eq!(snap_tray_icon_px(0), 16);
        assert_eq!(snap_tray_icon_px(16), 16);
        assert_eq!(snap_tray_icon_px(17), 20);
        assert_eq!(snap_tray_icon_px(20), 20);
        assert_eq!(snap_tray_icon_px(24), 24);
        assert_eq!(snap_tray_icon_px(30), 32);
        assert_eq!(snap_tray_icon_px(48), 32);
    }
}
