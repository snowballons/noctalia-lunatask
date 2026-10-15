# Lunatask for Noctalia (M0 scaffold)

> **M0 — ping only.** This plugin currently resolves your Lunatask token and
> verifies it with `GET /v1/ping`. Task/note/journal features land in M2–M5.

## Requirements

- Noctalia v5.2.1+ (verified with `noctalia v5.2.1`; `plugin_api = 22`)
- A Lunatask account + access token (*Settings → Access tokens* in the Lunatask desktop app)

## Setup

1. Add this repo as a source and enable the plugin:
   ```bash
   noctalia msg plugins source add dev path ~/Projects/active-projects/lunatask-noctalia-plugin/noctalia-lunatask
   noctalia msg plugins enable snowballons/lunatask
   ```
   (If `path` source syntax differs on your build, drop `lunatask/` under
   `$XDG_DATA_HOME/noctalia/plugins/` instead.)
2. Set the token — pick the most secure option you can:
   - `LUNATASK_ACCESS_TOKEN` env var (if your Noctalia process inherits it), or
   - `token_file` setting pointing at a file containing only the token, or
   - plain `token` setting (stored as plain text in Noctalia's settings).
3. Verify:
   ```bash
   noctalia msg plugin snowballons/lunatask:core all ping
   ```

## Privacy

- The token is never logged and never passed on a command line (uses `noctalia.http`).
- Plugin settings are plain TOML — never commit your token to a dotfiles repo.
  Prefer `token_file`.

## Limitations

- Lunatask's API is end-to-end encrypted: it never returns task names or note
  text, so this plugin can only manage items it created itself (tracked in a
  local registry from M1 on). No webhooks exist.
