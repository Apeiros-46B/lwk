use std::{collections::HashMap, path::PathBuf};

use argh::FromArgs;
use serde::Deserialize;

/// CLI arguments.
#[derive(Debug, FromArgs)]
pub struct Args {
    /// path to the toml config file
    #[argh(option, short = 'c')]
    pub config: Option<PathBuf>,

    /// whether to watch inputs for changes and rebuild incrementally
    #[argh(switch, short = 'w')]
    pub watch: bool,

    /// whether to also enable lua prints by default
    #[argh(switch, short = 'v')]
    pub verbose: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    pub build: BuildConfig,
    #[serde(default)]
    pub handlers: HandlerConfig,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BuildConfig {
    pub out_dir: PathBuf,
    pub pages_dir: PathBuf,
    #[serde(default)]
    pub modules_dir: Option<PathBuf>,
    #[serde(default)]
    pub components_dir: Option<PathBuf>,
    #[serde(default)]
    pub transforms_dir: Option<PathBuf>,
    #[serde(default)]
    pub config_file: Option<PathBuf>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct HandlerConfig {
    #[serde(default)]
    pub files: HashMap<String, HashMap<String, PathBuf>>,
    #[serde(default)]
    pub global: HashMap<String, PathBuf>,
}

impl BuildConfig {
    pub fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            !self.out_dir.exists() || self.out_dir.is_dir(),
            "in config: build.out_dir exists and is not a directory",
        );
        anyhow::ensure!(
            self.pages_dir.is_dir(),
            "in config: build.pages_dir is not a directory",
        );
        anyhow::ensure!(
            self.modules_dir.as_ref().is_none_or(|d| d.is_dir()),
            "in config: build.modules_dir is not a directory",
        );
        anyhow::ensure!(
            self.components_dir.as_ref().is_none_or(|d| d.is_dir()),
            "in config: build.components_dir is not a directory",
        );
        anyhow::ensure!(
            self.transforms_dir.as_ref().is_none_or(|d| d.is_dir()),
            "in config: build.transforms_dir is not a directory",
        );
        anyhow::ensure!(
            self.config_file.as_ref().is_none_or(|f| f.is_file()),
            "in config: build.config_file is not a file",
        );

        Ok(())
    }
}
