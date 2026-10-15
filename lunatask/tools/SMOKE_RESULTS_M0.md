# Smoke results — M0 (2026-10-15, live API, test area + notebook)

Token: throwaway test token (revoked after testing). Nothing secret is stored here.

| # | Check | Observed |
|---|---|---|
| T-01 | `ping` valid token | **200** `{"message":"pong"}` |
| T-02 | `ping` bad token | **401** `{"error":"Unauthorized"}` |
| T-05/06 | Create task / duplicate `source_id` | **201** then **204** No Content, no duplicate |
| Lookup | `GET /tasks?source=noctalia&source_id=…` | Returns the task (id, status, area…); **no `name`/`note` fields** — C1 confirmed live |
| T-08 | Partial `PUT {status:next}` | **200**, `previous_status: later → status: next` |
| Unknown id update | `PUT /tasks/0000…` | **404** |
| T-11 | Delete / delete again | **200** then **404** (404 = success for deletes) |
| V-05 | Create without `area_id` | **422** `{"errors":["area_id cannot be blank"]}` → **area_id is mandatory** |
| Notes | Create / dup / rename / replace / delete | Create **200** (no name/content echoed); dup **204**; rename **200**; content replace **200**; delete **200** |
| V-08 | Note without `notebook_id` | Accepted, stored with **`notebook_id: null`** (unfiled, not a default notebook) |
| V-07 | Two journal entries, same date | **Both accepted** with distinct IDs — same-date entries are allowed |
| Journal shape | `POST /journal_entries` | Returns `{id, date_on, created_at, updated_at}` only |

Cleanup: smoke tasks + notes deleted via API (verified `tasks?source…` empty).
Leftover: 2 journal entries for 2026-10-15 — no delete endpoint exists,
remove them in the Lunatask app.

Still open (needs Noctalia-hosted run): V-01 (`res.ok` semantics for non-2xx
inside `noctalia.http`), V-13 (env inheritance — token_file used instead).

## M2 live panel test (2026-10-15, second test token)

Created "M2 panel test" from the panel (area Test, priority -1,
scheduled 2026-10-16, with note): registry went `pending_create` → `synced`
with a real id. Lookup confirmed priority/scheduled_on stored server-side.

| # | Check | Observed |
|---|---|---|
| T-05 | Panel create in chosen area | Appears in Test area; registry `synced` |
| T-06 | Duplicate `source_id` via curl | **204**, lookup count stays **1** — no duplicate |
| V-15 | Complete via `PUT {status:completed}` | `completed_at` **auto-set**; completed task **still listed** by `GET ?source=&source_id=` |
| Side obs. | Completing clears `scheduled_on` | After complete, `scheduled_on` became `null` (was 2026-10-16) — M3 reconcile must expect this |
| V-06 | `GET ?source=` (no `source_id`) | Returns items (used for the count checks above); `nct-…` ids (letters, digits, dashes) accepted without issue |

Cleanup: test task deleted via API (lookup empty). Registry row left
`s synced` for a deleted remote id — orphan marking arrives in M3.
