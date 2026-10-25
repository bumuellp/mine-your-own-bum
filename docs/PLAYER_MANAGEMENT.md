# 🛡️ Player Management & Whitelisting

This guide explains crossplay player authentication, player access control, and how to whitelist both Java Edition and Bedrock Edition players.

---

## 🔒 Access Control Overview

When `whitelist_enabled: true` is set in `config/settings.yaml`, unauthorized players cannot join the server.

* **Java Edition Players**: Authenticated via Mojang session servers. Whitelist entries use standard Minecraft usernames (e.g., `"Steve"`). The container automatically resolves their Mojang UUIDs.
* **Bedrock Edition Players (Geyser / Floodgate)**: Because Mojang APIs do not index Microsoft / Xbox Gamertags, Bedrock players use deterministic **Floodgate UUIDs** (`00000000-0000-0000-xxxx-xxxxxxxxxxxx` derived mathematically from their numeric Xbox User ID).

---

## ⚖️ Understanding `/whitelist` vs `/fwhitelist`

When managing players in-game or via console, there are two distinct whitelist commands:

| Feature | Vanilla `/whitelist` | Floodgate `/fwhitelist` |
|---|---|---|
| **Origin** | Built into standard Minecraft | Provided by the Floodgate mod/plugin |
| **Intended For** | **Java Edition players** | **Bedrock Edition players** |
| **Lookup Mechanism** | Queries Mojang's session servers to resolve Java usernames to Mojang UUIDs. | Queries Xbox Live APIs in real-time to resolve Xbox Gamertags to Floodgate UUIDs. |
| **Bedrock Usage** | Can whitelist Bedrock players **only after** they have connected at least once using the dot prefix (`/whitelist add .Gamertag`). | Can whitelist Bedrock players **at any time**, even before they connect for the first time (`/fwhitelist add Gamertag`). |
| **Offline Mode Behavior** | If `online_mode: false`, can only add players who have already joined and exist in `usercache.json`. | Still resolves Xbox Gamertags via Floodgate. |

---

## 🎮 Whitelisting Bedrock Players

There are four ways to obtain the Floodgate UUID or whitelist Bedrock players:

### Method 1: Built-in Helper Script (Fastest for Git Configuration)

Run the included helper script directly from your workstation:

```bash
./scripts/get-bedrock-uuid.sh <Gamertag>
```

Example Output:
```text
Gamertag:       Alex
Xbox XUID:      2535412345678901
Floodgate UUID: 00000000-0000-0000-0009-011234567890

Add to config/settings.yaml:
  whitelist:
    - "00000000-0000-0000-0009-011234567890"  # .Alex (Bedrock)
```

Add the resulting UUID to `config/settings.yaml` under `minecraft.whitelist` and push to Git.

---

### Method 2: Public Web Lookup Tools

If you don't have terminal access, look up Floodgate UUIDs online using public lookup services:

* **[CraftMC Player Lookup](https://craftmc.net)**: Search by Xbox Gamertag to view profile details, XUID, and Floodgate UUID.
* **[mc-api.io](https://mc-api.io)**: Fast cross-edition player profile and Floodgate UUID resolver.

---

### Method 3: In-Game Floodgate Command (`/fwhitelist`)

If you or another player is an operator (`ops`), run `/fwhitelist` directly in-game:

```text
/fwhitelist add <Gamertag>
```

Floodgate contacts Xbox Live APIs, calculates the Floodgate UUID, and immediately updates `whitelist.json` on the persistent storage volume.

---

### Method 4: First-Join Workaround

If you are using standard `/whitelist` commands:
1. Temporarily pause the whitelist:
   ```text
   /whitelist off
   ```
2. Have the Bedrock player connect to the server once (allowing Geyser/Floodgate to register their profile in `usercache.json`).
3. Whitelist them using the dot prefix (`.`):
   ```text
   /whitelist add .<Gamertag>
   ```
4. Re-enable the whitelist:
   ```text
   /whitelist on
   ```

> [!TIP]
> For instructions on whitelisting players on offline-mode / non-premium servers, see the [Troubleshooting Guide](TROUBLESHOOTING.md#players-not-found-or-rejected-with-whitelist-enabled).

---

## 👑 Server Operators (`ops`)

Server operators have permission level 4 access (commands like `/gamemode`, `/teleport`, `/fwhitelist`, `/kick`, `/ban`, and `/stop`).

Configure initial operators in `config/settings.yaml`:

```yaml
minecraft:
  ops:
    - "Steve" # Java player
    - "00000000-0000-0000-0009-011234567890" # Bedrock player (Floodgate UUID)
```

Or grant operator status in-game (requires an existing operator or console access):
```text
/op Steve
/op .BedrockGamertag
```
