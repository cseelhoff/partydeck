use crate::monitor::Monitor;
use crate::app::PartyConfig;
use crate::profiles::GUEST_NAMES;

#[derive(Clone)]
pub struct Instance {
    pub devices: Vec<usize>,
    pub profname: String,
    pub profselection: usize,
    pub monitor: usize,
    pub width: u32,
    pub height: u32,
}

pub fn set_instance_resolutions(
    instances: &mut Vec<Instance>,
    primary_monitor: &Monitor,
    cfg: &PartyConfig,
) {
    let (basewidth, baseheight) = (primary_monitor.width(), primary_monitor.height());
    let playercount = instances.len();

    for (player_index, instance) in instances.iter_mut().enumerate() {
        let (mut w, mut h) = match playercount {
            1 => (basewidth, baseheight),
            2 => {
                if cfg.vertical_two_player {
                    (basewidth / 2, baseheight)
                } else {
                    (basewidth, baseheight / 2)
                }
            }
            5 if !cfg.vertical_two_player => {
                if player_index < 3 {
                    (basewidth / 3, baseheight / 2)
                } else {
                    (basewidth / 2, baseheight / 2)
                }
            }
            _ => (basewidth / 2, baseheight / 2),
        };
        if h < 600 && cfg.gamescope_fix_lowres {
            let ratio = w as f32 / h as f32;
            h = 600;
            w = (h as f32 * ratio) as u32;
        }
        instance.width = w;
        instance.height = h;
    }
}

pub fn set_instance_resolutions_multimonitor(
    instances: &mut Vec<Instance>,
    monitors: &Vec<Monitor>,
    cfg: &PartyConfig,
) {
    let mut mon_playercounts: Vec<usize> = vec![0; monitors.len()];
    for instance in instances.iter() {
        let mon = instance.monitor;
        mon_playercounts[mon] += 1;
    }

    let mut mon_playerindices: Vec<usize> = vec![0; monitors.len()];
    for instance in instances.iter_mut() {
        let player_index = mon_playerindices[instance.monitor];
        mon_playerindices[instance.monitor] += 1;
        let playercount = mon_playercounts[instance.monitor];
        let (basewidth, baseheight) = (
            monitors[instance.monitor].width(),
            monitors[instance.monitor].height(),
        );

        let (mut w, mut h) = match playercount {
            1 => (basewidth, baseheight),
            2 => {
                if cfg.vertical_two_player {
                    (basewidth / 2, baseheight)
                } else {
                    (basewidth, baseheight / 2)
                }
            }
            5 if !cfg.vertical_two_player => {
                if player_index < 3 {
                    (basewidth / 3, baseheight / 2)
                } else {
                    (basewidth / 2, baseheight / 2)
                }
            }
            _ => (basewidth / 2, baseheight / 2),
        };
        if h < 600 && cfg.gamescope_fix_lowres {
            let ratio = w as f32 / h as f32;
            h = 600;
            w = (h as f32 * ratio) as u32;
        }
        instance.width = w;
        instance.height = h;
    }
}

/// Normalized `(x, y, width, height)` cells (each in `0.0..=1.0`) describing how
/// `player_count` instances are partitioned within a single monitor. This
/// mirrors the partitioning the KWin scripts apply at launch (see
/// `res/splitscreen_kwin.js` and `res/splitscreen_kwin_vertical.js`) so the
/// instance menu can render a faithful preview. `vertical` selects the
/// two-player split orientation.
pub fn normalized_layout(player_count: usize, vertical: bool) -> Vec<(f32, f32, f32, f32)> {
    match player_count {
        0 => Vec::new(),
        1 => vec![(0.0, 0.0, 1.0, 1.0)],
        2 => {
            if vertical {
                vec![(0.0, 0.0, 0.5, 1.0), (0.5, 0.0, 0.5, 1.0)]
            } else {
                vec![(0.0, 0.0, 1.0, 0.5), (0.0, 0.5, 1.0, 0.5)]
            }
        }
        3 => vec![
            (0.0, 0.0, 1.0, 0.5),
            (0.0, 0.5, 0.5, 0.5),
            (0.5, 0.5, 0.5, 0.5),
        ],
        4 => vec![
            (0.0, 0.0, 0.5, 0.5),
            (0.5, 0.0, 0.5, 0.5),
            (0.0, 0.5, 0.5, 0.5),
            (0.5, 0.5, 0.5, 0.5),
        ],
        5 if !vertical => vec![
            (0.0, 0.0, 1.0 / 3.0, 0.5),
            (1.0 / 3.0, 0.0, 1.0 / 3.0, 0.5),
            (2.0 / 3.0, 0.0, 1.0 / 3.0, 0.5),
            (0.0, 0.5, 0.5, 0.5),
            (0.5, 0.5, 0.5, 0.5),
        ],
        n => {
            // Beyond what the KWin scripts handle; fall back to an even grid so
            // the preview still communicates relative placement.
            let cols = (n as f32).sqrt().ceil() as usize;
            let rows = n.div_ceil(cols);
            let (cw, ch) = (1.0 / cols as f32, 1.0 / rows as f32);
            (0..n)
                .map(|i| {
                    let (c, r) = (i % cols, i / cols);
                    (c as f32 * cw, r as f32 * ch, cw, ch)
                })
                .collect()
        }
    }
}

pub fn set_instance_names(instances: &mut Vec<Instance>, profiles: &[String]) {
    let mut guests = GUEST_NAMES.to_vec();

    for instance in instances {
        if instance.profselection == 0 {
            let i = fastrand::usize(..guests.len());
            instance.profname = format!(".{}", guests[i]);
            guests.swap_remove(i);
        } else {
            instance.profname = profiles[instance.profselection].to_owned();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::normalized_layout;

    #[test]
    fn horizontal_five_player_layout_fills_both_rows() {
        let layout = normalized_layout(5, false);

        assert_eq!(layout[0], (0.0, 0.0, 1.0 / 3.0, 0.5));
        assert_eq!(layout[2], (2.0 / 3.0, 0.0, 1.0 / 3.0, 0.5));
        assert_eq!(layout[3], (0.0, 0.5, 0.5, 0.5));
        assert_eq!(layout[4], (0.5, 0.5, 0.5, 0.5));
    }
}
