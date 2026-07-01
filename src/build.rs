use anyhow::Result;
use mlua::{Lua, Table};

use crate::config::Config;

pub fn run_full(config: &Config) -> Result<()> {
    let lua = Lua::new();

    let config: Table = if let Some(path) = &config.build.config_file {
        let config_content = std::fs::read_to_string(path)?;
        lua.load(&config_content).eval()?
    } else {
        lua.create_table()?
    };
    lua.globals().set("CONFIG", config)?;

    Ok(())
}

pub fn run_incremental(config: &Config) -> Result<()> {
    let _ = config;
    todo!()
}
