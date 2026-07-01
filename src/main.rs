mod build;
mod config;

use std::path::PathBuf;

use anyhow::{ensure, Context};
use log::LevelFilter;

use config::*;

fn main() -> anyhow::Result<()> {
    let args: Args = argh::from_env();

    let level = if args.verbose { LevelFilter::Debug } else { LevelFilter::Info };
    env_logger::builder()
        .filter_level(level)
        .format_timestamp_millis()
        .init();

    let config_path = args.config.unwrap_or(PathBuf::from("lwk.toml"));
    ensure!(
        config_path.is_file(),
        "config file '{}' is not a regular file", config_path.to_string_lossy(),
    );

    // dir the config file is in
    let config_path_canon = config_path.canonicalize()?;
    let Some(config_dir) = config_path_canon.parent() else {
        anyhow::bail!("config file does not have a parent directory");
    };

    let config_contents = std::fs::read_to_string(config_path)
        .context("unable to read config file")?;
    let config: Config = toml::from_str(&config_contents)
        .context("config file is malformed")?;

    std::env::set_current_dir(config_dir)?;
    config.build.validate()?;

    if args.watch {
        build::run_incremental(&config)
    } else {
        build::run_full(&config)
    }
}
