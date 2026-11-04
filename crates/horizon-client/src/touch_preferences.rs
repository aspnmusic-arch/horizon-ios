//! Persistent touch layout preferences for the native launcher.
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::Path,
    sync::{OnceLock, RwLock},
};

use serde::{Deserialize, Serialize};

use crate::touch::{self, Control, Rect};

const WIDTH: f32 = 640.0;
const HEIGHT: f32 = 360.0;
const FILE: &str = "horizon-touch-controls.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Button {
    pub id: String,
    pub x: f32,
    pub y: f32,
    pub scale: f32,
    pub visible: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub opacity: f32,
    pub buttons: Vec<Button>,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            opacity: 1.0,
            buttons: Vec::new(),
        }
    }
}

impl Preferences {
    pub fn validate(&self) -> Result<(), &'static str> {
        if !self.opacity.is_finite() || !(0.2..=1.0).contains(&self.opacity) {
            return Err("Opacity must be between 20% and 100%.");
        }
        let mut seen = HashSet::new();
        for b in &self.buttons {
            if !IDS.contains(&b.id.as_str()) || !seen.insert(&b.id) {
                return Err("Unknown or duplicate control.");
            }
            if !b.x.is_finite()
                || !b.y.is_finite()
                || !b.scale.is_finite()
                || !(0.0..=1.0).contains(&b.x)
                || !(0.0..=1.0).contains(&b.y)
                || !(0.5..=2.0).contains(&b.scale)
            {
                return Err("Control position or size is outside the supported range.");
            }
        }
        Ok(())
    }
}

const IDS: [&str; 14] = [
    "forward",
    "back",
    "left",
    "right",
    "sneak",
    "jump",
    "view",
    "chat",
    "pause",
    "inventory",
    "attack",
    "use",
    "sprint",
    "drop",
];

pub fn id(control: Control) -> Option<&'static str> {
    Some(match control {
        Control::Forward => "forward",
        Control::Back => "back",
        Control::Left => "left",
        Control::Right => "right",
        Control::Sneak => "sneak",
        Control::Jump => "jump",
        Control::Perspective => "view",
        Control::Chat => "chat",
        Control::Pause => "pause",
        Control::Inventory => "inventory",
        Control::Attack => "attack",
        Control::Use => "use",
        Control::Sprint => "sprint",
        Control::Drop => "drop",
        Control::Hotbar(_) => return None,
    })
}

fn load(path: &Path) -> Preferences {
    let mut data = Vec::new();
    let read = File::open(path)
        .and_then(|file| file.take(65_537).read_to_end(&mut data))
        .is_ok();
    if !read || data.len() > 65_536 {
        return Preferences::default();
    }
    serde_json::from_slice::<Preferences>(&data)
        .ok()
        .filter(|p| p.validate().is_ok())
        .unwrap_or_default()
}

fn store(path: &Path, prefs: &Preferences) -> io::Result<()> {
    prefs
        .validate()
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let bytes = serde_json::to_vec(prefs).map_err(io::Error::other)?;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp = path.with_file_name(format!("{FILE}.{}.{}.tmp", std::process::id(), nonce));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

fn cached() -> &'static RwLock<Preferences> {
    static SETTINGS: OnceLock<RwLock<Preferences>> = OnceLock::new();
    SETTINGS.get_or_init(|| RwLock::new(load(Path::new(FILE))))
}

pub fn current() -> Preferences {
    cached()
        .read()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
}

/// Save first; a failed write leaves the active layout untouched.
pub fn save(prefs: Preferences) -> io::Result<()> {
    store(Path::new(FILE), &prefs)?;
    *cached()
        .write()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = prefs;
    Ok(())
}

/// Resolve unmodified controls using the same default layout as the game.
pub fn editor(prefs: &Preferences) -> Preferences {
    let mut buttons: Vec<Button> = touch::layout(WIDTH, HEIGHT)
        .into_iter()
        .filter_map(|(control, r)| {
            let id = id(control)?;
            Some(
                prefs
                    .buttons
                    .iter()
                    .find(|b| b.id == id)
                    .cloned()
                    .unwrap_or_else(|| Button {
                        id: id.to_owned(),
                        x: (r[0] + r[2] / 2.0) / WIDTH,
                        y: (r[1] + r[3] / 2.0) / HEIGHT,
                        scale: 1.0,
                        visible: true,
                    }),
            )
        })
        .collect();
    for (control, x, y) in EXTRA {
        let id = id(control).expect("extra control has an id");
        buttons.push(
            prefs
                .buttons
                .iter()
                .find(|b| b.id == id)
                .cloned()
                .unwrap_or_else(|| Button {
                    id: id.to_owned(),
                    x,
                    y,
                    scale: 1.0,
                    visible: false,
                }),
        );
    }
    Preferences {
        opacity: prefs.opacity,
        buttons,
    }
}

const EXTRA: [(Control, f32, f32); 4] = [
    (Control::Attack, 0.82, 0.48),
    (Control::Use, 0.92, 0.48),
    (Control::Sprint, 0.07, 0.43),
    (Control::Drop, 0.75, 0.80),
];

/// Apply one layout to drawing, hit testing and the AirPlay controller.
pub fn layout(w: f32, h: f32, prefs: &Preferences) -> Vec<(Control, Rect)> {
    let mut all = touch::layout(w, h);
    let size = touch::button_size(h);
    for (control, x, y) in EXTRA {
        all.push((
            control,
            [x * w - size / 2.0, y * h - size / 2.0, size, size],
        ));
    }
    all.into_iter()
        .filter_map(|(control, mut r)| {
            // Extra buttons do not appear until enabled in the editor.
            if matches!(
                control,
                Control::Attack | Control::Use | Control::Sprint | Control::Drop
            ) && !prefs
                .buttons
                .iter()
                .any(|b| id(control) == Some(b.id.as_str()) && b.visible)
            {
                return None;
            }
            if let Some(b) = id(control).and_then(|id| prefs.buttons.iter().find(|b| b.id == id)) {
                if !b.visible {
                    return None;
                }
                r[2] = (r[2] * b.scale).min(w.max(0.0));
                r[3] = (r[3] * b.scale).min(h.max(0.0));
                r[0] = (b.x * w - r[2] / 2.0).clamp(0.0, (w - r[2]).max(0.0));
                r[1] = (b.y * h - r[3] / 2.0).clamp(0.0, (h - r[3]).max(0.0));
            }
            Some((control, r))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn edited_layout_changes_hit_testing_and_keeps_the_hotbar() {
        let mut prefs = Preferences::default();
        prefs.buttons.push(Button {
            id: "jump".into(),
            x: 0.5,
            y: 0.4,
            scale: 1.5,
            visible: true,
        });
        prefs.buttons.push(Button {
            id: "chat".into(),
            x: 0.5,
            y: 0.1,
            scale: 1.0,
            visible: false,
        });
        let layout = layout(640.0, 360.0, &prefs);
        assert_eq!(touch::hit(&layout, (320.0, 144.0)), Some(Control::Jump));
        assert!(!layout.iter().any(|(control, _)| *control == Control::Chat));
        assert_eq!(
            layout
                .iter()
                .filter(|(control, _)| matches!(control, Control::Hotbar(_)))
                .count(),
            9
        );
    }
    #[test]
    fn optional_attack_is_hidden_until_enabled_and_releases_after_touch() {
        let defaults = layout(640.0, 360.0, &Preferences::default());
        assert!(
            !defaults
                .iter()
                .any(|(control, _)| *control == Control::Attack)
        );
        let mut prefs = editor(&Preferences::default());
        let attack = prefs.buttons.iter_mut().find(|b| b.id == "attack").unwrap();
        attack.visible = true;
        attack.x = 0.7;
        attack.y = 0.3;
        let customized = layout(640.0, 360.0, &prefs);
        let mut fingers = touch::Touches::default();
        assert_eq!(
            fingers.start(1, (448.0, 108.0), 0.0, &customized),
            [touch::Out::Press(Control::Attack)]
        );
        assert_eq!(fingers.end(1), [touch::Out::Release(Control::Attack)]);
    }

    #[test]
    fn invalid_preferences_are_rejected_and_persistence_round_trips() {
        let root = std::env::temp_dir().join(format!(
            "horizon-touch-prefs-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join(FILE);
        let mut prefs = editor(&Preferences::default());
        prefs.opacity = 0.6;
        prefs.buttons[0].x = 0.75;
        store(&path, &prefs).unwrap();
        assert_eq!(load(&path), prefs);
        prefs.buttons[0].x = 0.33;
        store(&path, &prefs).unwrap();
        assert_eq!(load(&path), prefs);
        let previous = fs::read(&path).unwrap();
        prefs.buttons[0].scale = 3.0;
        assert!(store(&path, &prefs).is_err());
        assert_eq!(fs::read(&path).unwrap(), previous);
        assert!(
            Preferences {
                opacity: f32::NAN,
                buttons: vec![]
            }
            .validate()
            .is_err()
        );
        fs::write(&path, vec![b' '; 65_537]).unwrap();
        assert_eq!(load(&path), Preferences::default());
        fs::remove_dir_all(root).unwrap();
    }
}
