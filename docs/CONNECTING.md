# 🎮 Connecting to the Server

This guide explains how players can connect to the server across all supported platforms. No client-side mods are required.

Both **Minecraft Java Edition** and **Minecraft Bedrock Edition** players can play together on the same world simultaneously.

---

## 🌐 Network Ports Reference

| Edition | Protocol | Port | Description |
|---|:---:|:---:|---|
| **Java Edition** | TCP | `25565` | Standard Minecraft Java port. |
| **Bedrock Edition** | UDP | `19132` | Standard Minecraft Bedrock port (routed through GeyserMC). |

---

## ☕ Minecraft Java Edition (PC, Mac, Linux)

1. Open the official **Minecraft Launcher** (or third-party launcher such as Prism Launcher or Modrinth App).
2. Launch Minecraft matching the server version (e.g., `1.21.x`).
3. Navigate to **Multiplayer > Add Server**.
4. Configure connection:
   * **Server Name**: Any name (e.g., `Mine Your Own Bum`).
   * **Server Address**: Your configured domain (e.g., `mc.example.com`) or the server's public IPv4 address.
   * Default port `25565` does not need to be specified.
5. Click **Done** and join the server.

---

## 📱 Minecraft Bedrock Edition (Windows 10/11, iOS, Android)

1. Launch **Minecraft (Bedrock)**.
2. Navigate to **Play > Servers tab > Add Server** (scroll to the bottom of the server list).
3. Configure connection:
   * **Server Name**: `Mine Your Own Bum`.
   * **Server Address**: Your configured domain (e.g., `mc.example.com`) or the server's public IPv4 address.
   * **Port**: `19132` (standard Bedrock UDP port).
4. Tap **Save** and select the server to connect.

---

## 🕹️ Consoles (Xbox, PlayStation, Nintendo Switch)

Console editions of Minecraft do not include an "Add External Server" button by default due to platform restrictions. You can easily connect using one of the following methods:

### Method 1: BedrockTogether App (Recommended — Easiest)

Download the free **[BedrockTogether](https://bedrocktogether.net/)** app on an iOS or Android smartphone connected to the **same Wi-Fi network** as your console:

1. Open the BedrockTogether app on your phone.
2. Enter your server's domain/IP and port (`19132`), then tap **Run**.
3. On your console, launch Minecraft and go to **Friends > LAN Games**.
4. The server will appear automatically as a joinable local game!

### Method 2: DNS Redirection

Alternatively, redirect one of the featured console servers (e.g. The Hive, InPVP) to your server using public DNS tools:
* **[BedrockConnect](https://github.com/Pugmatt/BedrockConnect)**: Change your console's primary DNS settings to point to a public BedrockConnect server list manager.
* **MC-Server-Connector**: Companion app available on Android/iOS.

---

## ⚡ Direct IP Connection During Rapid Restarts

> [!TIP]
> If you stop and restart the server within a short timeframe, intermediate DNS resolvers and your client's Java runtime may cache the temporary negative DNS response for up to 10 minutes.
>
> During rapid testing or restarts, bypass DNS completely by connecting directly to the server's public IPv4 address (e.g., `142.132.x.x`) shown in the GitHub Actions **Job Summary** or Discord bot response.
>
> For full technical details and DNS cache flushing commands, see the [Troubleshooting Guide](TROUBLESHOOTING.md).
