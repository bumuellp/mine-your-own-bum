//! Shared domain types for the Minecraft Discord bot

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActiveWorkflow {
    Start,
    Stop,
}

/// Ping result containing connectivity status and the resolved remote IP address if available
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PingResult {
    pub is_online: bool,
    pub ip: Option<String>,
}

/// Declarative Minecraft loader, version, modpack, and pre-resolved mod side classifications.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ModConfig {
    pub server_type: String,
    pub mc_version: String,
    pub modrinth_modpack: String,
    pub client_required_mods: String,
    pub client_optional_mods: String,
    pub server_only_mods: String,
    pub curseforge_projects: String,
}

fn parse_csv_or_lines(raw: &str) -> Vec<String> {
    raw.split([',', '\n'])
        .map(|s| {
            s.trim()
                .trim_matches(|c: char| matches!(c, '[' | ']' | '"' | '\'' | ' ' | '\t'))
                .to_string()
        })
        .filter(|s| !s.is_empty())
        .collect()
}

impl ModConfig {
    /// Returns Modrinth mods with `client_side == "required"`.
    pub fn required_modrinth_mods(&self) -> Vec<String> {
        parse_csv_or_lines(&self.client_required_mods)
    }

    /// Returns Modrinth mods with `client_side == "optional"`.
    pub fn optional_modrinth_mods(&self) -> Vec<String> {
        parse_csv_or_lines(&self.client_optional_mods)
    }

    /// Returns Modrinth mods with `client_side == "unsupported"` (server-only).
    pub fn server_modrinth_mods(&self) -> Vec<String> {
        parse_csv_or_lines(&self.server_only_mods)
    }

    /// Returns all configured CurseForge project entries.
    pub fn client_curseforge_mods(&self) -> Vec<String> {
        parse_csv_or_lines(&self.curseforge_projects)
    }

    /// Returns `true` if connecting clients must install a modpack or client-required mods.
    pub fn requires_client_mods(&self) -> bool {
        !self.modrinth_modpack.trim().is_empty()
            || !self.required_modrinth_mods().is_empty()
            || !self.client_curseforge_mods().is_empty()
    }

    /// Returns `true` if Geyser is present (or when no mod config was injected, preserving default crossplay display).
    pub fn has_bedrock_crossplay(&self) -> bool {
        let all_empty = self.modrinth_modpack.trim().is_empty()
            && self.client_required_mods.trim().is_empty()
            && self.client_optional_mods.trim().is_empty()
            && self.server_only_mods.trim().is_empty()
            && self.curseforge_projects.trim().is_empty();
        if all_empty {
            return true;
        }
        self.server_modrinth_mods()
            .iter()
            .chain(self.optional_modrinth_mods().iter())
            .chain(self.required_modrinth_mods().iter())
            .any(|m| {
                m.split(':')
                    .next()
                    .unwrap_or(m)
                    .trim()
                    .eq_ignore_ascii_case("geyser")
            })
    }
}
