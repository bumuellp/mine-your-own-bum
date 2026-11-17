//! `mc-agent` library crate exposing auth, config, Discord webhooks, HTTP transport,
//! domain API routing, log parsing/tailing, RCON, and host telemetry modules.

pub mod api;
pub mod auth;
pub mod config;
pub mod discord;
pub mod http;
pub mod log_parser;
pub mod log_watcher;
pub mod rcon;
pub mod system;
