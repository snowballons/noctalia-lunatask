# Lunatask

Capture tasks, notes, and journal entries to your Lunatask account without
leaving the Noctalia desktop shell — from the launcher in a few keystrokes,
or from a manager panel with editing, completion, and deletion.

Lunatask is end-to-end encrypted: its API never returns task names or note
text. This plugin can only list and manage items **it** created itself. That
limitation is by Lunatask's design, not a missing feature — see Notes below.

## Plugin

| Field | Value |
| --- | --- |
| ID | `snowballons/lunatask` |
| Entries | Bar widget: `button`; panel: `manager`; service: `core`; launcher: `capture` |
| Launcher Prefix | `/lt` |

## Requirements

- Noctalia v5 (v5.2.1 tested; `plugin_api = 24` needs v5.0.0-beta.9 or newer).
- `chmod` on `PATH` (declared in `plugin.toml`; used once per start to lock
  the plugin data directory to owner-only access).
- A Lunatask account and an access token, created in the Lunatask desktop app
  under *Settings → Access tokens*.

## Usage

Open the manager panel:

```sh
noctalia msg panel-toggle snowballons/lunatask:manager
```

The panel has **Tasks**, **Notes**, and **Journal** tabs. The primary action
(`+ New task`, `+ New note`, journal `Create`) lives in a sticky footer, so it
stays visible while the list scrolls. Task rows show the Lunatask status
(`later`, `next`, …, `completed`) next to the sync state; completed tasks lose
their Complete button. Deleting asks for a second confirming click (unless
`confirm_delete` is off). Refresh re-reads metadata from Lunatask and marks
items deleted elsewhere as orphaned.

Add the bar widget with type `snowballons/lunatask:button` for one-click
access to the panel.

Launcher quick capture behind `/lt`:

- `/lt Buy milk` → rows for *Create task* (default area + status),
  *Create note*, and *Add to today's journal*, plus up to 5 matching items
  you created before. Typing never touches the network; only activating a
  result does, and the outcome arrives as a notification.
- Picking a registry match opens the manager panel on that item.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `token` | `string` | `""` | Access token as plain text. Least secure option; prefer `token_file`. |
| `token_file` | `file` | `""` | Path to a file containing only the token. Recommended. |
| `areas` | `string_map` | `{}` | Name → area UUID. Copy UUIDs from the area settings in the Lunatask app. Required for task creation; the plugin cannot discover areas. |
| `default_area` | `string` | `""` | Name from `areas` used for `/lt` capture. With a single area configured, it is used even when this is empty. |
| `notebooks` | `string_map` | `{}` | Name → notebook UUID (optional). Notes without a notebook land unfiled. |
| `default_notebook` | `string` | `""` | Notebook for quick capture; empty omits `notebook_id`. |
| `default_task_status` | `select` | `later` | Status for new tasks: `later`, `next`, `started`, `waiting`. |
| `cache_bodies` | `bool` | `false` | Store task notes / note bodies / journal excerpts as plain text locally so they can be prefilled and edited. Off means retyping full replacement text. |
| `confirm_delete` | `bool` | `true` | Require a second click before deleting. |
| `source_tag` | `string` | `noctalia` | Advanced. Sent as `source` on every create; changing it orphans reconciliation of older items. |
| `max_retries` | `int` | `1` (0–3) | Advanced. Automatic retries for transient failures (network/5xx/timeout). |

Token resolution order: `LUNATASK_ACCESS_TOKEN` environment variable, then
`token_file`, then `token`. Never put the token in Nix-managed
`programs.noctalia.settings` (world-readable store); use `token_file`.

## IPC

```sh
noctalia msg plugin snowballons/lunatask:core all ping
noctalia msg plugin snowballons/lunatask:core all refresh
```

`ping` verifies the token against `GET /v1/ping` (`pong` on success).
`refresh` reconciles the local registry with Lunatask (status updates,
orphan detection). The last ping outcome is also readable at
`<data-dir>/status.json` as `{ok, status, kind, at}`.

## Notes

- **Read limitation.** The Lunatask API returns metadata only (ids, status,
  dates) — never names or content. The panel lists only items this plugin
  created (tracked in `registry.json`); anything created in the Lunatask app
  is invisible here. Renaming an item in the Lunatask app never reflects
  here, though moves and re-dates do after Refresh.
- **Not end-to-end encrypted.** The Lunatask apps are; this plugin sends
  plaintext over TLS like any API client. Decide what you are comfortable
  capturing (journal entries especially).
- **Notes replace, never append.** Saving note content replaces the entire
  body server-side; the editor warns every time. With `cache_bodies` off the
  content field starts empty and renaming/moving never touches the text.
- **Journal is create-only.** The API exposes no update, delete, or list for
  journal entries. Failed journal creates never auto-retry (no idempotency
  pair exists — a retry could silently double-post).
- **Files written.** `<state>/noctalia/plugins/data/snowballons/lunatask/`:
  `registry.json` (ids + titles; bodies only with `cache_bodies`),
  `status.json` (last ping outcome). The directory is `chmod 700` on every
  start. Nothing is persisted inside the plugin directory (it is rewritten on
  update).
- **Processes spawned.** One: `chmod 700 <data-dir>` per service start.
  Credentials travel via `noctalia.http` headers and never appear on a
  command line. Logs and notifications carry status codes/kinds only — never
  the token or your text.
- **Network.** One request in flight, FIFO queue, 30 s deadline, no
  background polling. Refresh runs at service start and on demand (panel
  button or IPC). There is no documented rate limit; the client stays polite
  by default.
- **Troubleshooting.** `config` → set the token; `auth` → token wrong or
  revoked; `plan` → free-plan limit, subscription needed; `not_found` →
  deleted elsewhere (Forget it); `validation` → check area/notebook/date;
  `server`/`network`/`timeout` → automatic retry, then Retry button.
