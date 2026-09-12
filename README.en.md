# Ruminote · KOReader Plugin

[简体中文](README.md) | **English**

> Good sentences deserve a second chew.

A [KOReader](https://github.com/koreader/koreader) plugin that automatically syncs your ebook highlights to the **Rumi书摘 (Ruminote)** cloud, so you can review and revisit them anytime in the Rumi书摘 WeChat Mini Program.

## 🚧 Current status

**The Rumi书摘 Mini Program has not launched yet, so the sync feature is not available for now.** This plugin's docs will be updated once the Mini Program is live, at which point you can bind and use it. You may install the plugin now and wait for the launch announcement.

## ⚠️ Prerequisite

This plugin is the KOReader sync client for the **Rumi书摘 (Ruminote)** WeChat Mini Program — it is **not a standalone tool**:

- You need a Rumi书摘 Mini Program account (search "Rumi书摘" in WeChat; *available after launch*).
- To bind, generate a **6-digit pairing code** in the Mini Program and enter it in the plugin.
- Highlights are synced to the Rumi书摘 cloud and are visible only to you.

If you just want local-only highlight export without Rumi书摘, this plugin is not for you.

## Features

- Adds a "Ruminote" entry to KOReader's Tools menu: Bind account / Sync now / Pending queue / About
- **Auto-sync**: periodic (every 10 min) + on close/suspend/resume + on highlight (some versions) + manual — all silent; uploads when online, queues when offline
- **Incremental upload**: locally tracks synced fingerprints, only uploads new highlights, never re-uploads
- **Idempotent dedup**: each highlight's `highlight_id` is a sha256 fingerprint (computed by `fingerprint.lua`, matching the cloud implementation), deduplicated server-side
- **6-digit pairing-code binding**: exchanged for a long-lived `device_token`; each device belongs to exactly one account globally — to rebind to a new account, unbind it first in the original account's Mini Program

## Installation

### Option 1: App Store plugin (recommended, requires AppStore first)

If you have the community [AppStore plugin](https://github.com/omer-faruq/appstore.koplugin) installed:

1. KOReader → Tools → **App Store** → Plugins
2. Search `ruminote` → **Install**
3. Restart KOReader

### Option 2: Manual install (universal)

1. Download `ruminote.koplugin.zip` from [Releases](https://github.com/Rumi-Note/ruminote.koplugin/releases) and unzip to get the `ruminote.koplugin/` folder
2. Copy it into KOReader's `plugins/` directory:
   - **Android**: `/sdcard/koreader/plugins/`
   - **Kobo / Kindle**: `koreader/plugins/`
   - **Desktop (Linux)**: `~/.config/koreader/plugins/`
   - ⚠️ Make sure it's `plugins/ruminote.koplugin/main.lua`, not nested one level deeper
3. Fully restart KOReader (kill and relaunch, not just back out)
4. Reading view → Tools menu → find "Ruminote 如觅书摘"

### Binding

In the Mini Program: "Me → My Devices → Bind new device" to generate a 6-digit pairing code → in the plugin choose "Bind account" and enter it → once bound, highlights sync automatically.

## Files

```
_meta.lua        # Plugin metadata (display name / description / version)
main.lua         # Core: menu, offline queue, incremental/auto sync, binding
fingerprint.lua  # sha256 highlight fingerprint (matches cloud, for idempotent dedup)
```

> Internal identifier is `ruminate`; user-facing brand name is **Ruminote 如觅书摘**.

## Compatibility

- Requires a reasonably recent stable KOReader (uses the `annotations` table)
- `onSaveHighlight` does not fire on some versions → falls back to scanning the current book's annotations on sync (multi-source), plus periodic/on-close triggers

## Related

- Mini Program: search "Rumi书摘" in WeChat (*available after launch*)

## License

GPL-3.0 (see LICENSE).
