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
