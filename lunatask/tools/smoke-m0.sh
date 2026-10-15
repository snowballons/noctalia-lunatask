#!/usr/bin/env bash
# smoke-m0.sh — Appendix D curl smoke tests, M0.
# Reads the token from $LUNATASK_TOKEN (never pass it as an argument).
# Usage:
#   read -rs LUNATASK_TOKEN && export LUNATASK_TOKEN
#   export AREA_ID="<test-area-uuid>" NOTEBOOK_ID="<test-notebook-uuid>"
#   ./smoke-m0.sh
# Cleanup is built in: tasks + notes created here are deleted at the end.
# Journal entries have no delete endpoint — remove them in the Lunatask app.
set -u
: "${LUNATASK_TOKEN:?set LUNATASK_TOKEN first (read -rs LUNATASK_TOKEN && export LUNATASK_TOKEN)}"
: "${AREA_ID:?set AREA_ID}"
: "${NOTEBOOK_ID:?set NOTEBOOK_ID}"
API=https://api.lunatask.app/v1
H=(-H "Authorization: bearer $LUNATASK_TOKEN" -H "Content-Type: application/json")

say() { echo "=== $* ==="; }

say "0. ping (expect pong)"
curl -sS "${H[@]}" "$API/ping"; echo

say "1. create task (expect 201, no name/note in body)"
curl -sS "${H[@]}" -X POST "$API/tasks" \
  -d "{\"area_id\":\"$AREA_ID\",\"name\":\"smoke test\",\"source\":\"noctalia\",\"source_id\":\"smoke-m0-1\"}"; echo

say "2. duplicate create (expect 204, empty body)"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${H[@]}" -X POST "$API/tasks" \
  -d "{\"area_id\":\"$AREA_ID\",\"name\":\"smoke test\",\"source\":\"noctalia\",\"source_id\":\"smoke-m0-1\"}"

say "3. lookup by source_id (recover id)"
curl -sS "${H[@]}" "$API/tasks?source=noctalia&source_id=smoke-m0-1"; echo

TID=$(curl -sS "${H[@]}" "$API/tasks?source=noctalia&source_id=smoke-m0-1" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['tasks'][0]['id'])")
echo "TID=$TID"

say "4. partial update (expect 200, status next)"
curl -sS "${H[@]}" -X PUT "$API/tasks/$TID" -d '{"status":"next"}'; echo

say "5. delete (expect 200)"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${H[@]}" -X DELETE "$API/tasks/$TID"

say "6. delete again (expect 404 — plugin treats as success)"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${H[@]}" -X DELETE "$API/tasks/$TID"

say "7. create without area_id (record status; observed 422)"
curl -sS "${H[@]}" -X POST "$API/tasks" -d '{"name":"no area"}'; echo

say "8. notes: create / dup-204 / lookup / rename / replace / delete"
curl -sS "${H[@]}" -X POST "$API/notes" \
  -d "{\"notebook_id\":\"$NOTEBOOK_ID\",\"name\":\"smoke note\",\"content\":\"hello\",\"source\":\"noctalia\",\"source_id\":\"smoke-n1\"}"; echo
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${H[@]}" -X POST "$API/notes" \
  -d "{\"notebook_id\":\"$NOTEBOOK_ID\",\"name\":\"smoke note\",\"content\":\"hello\",\"source\":\"noctalia\",\"source_id\":\"smoke-n1\"}"
NID=$(curl -sS "${H[@]}" "$API/notes?source=noctalia&source_id=smoke-n1" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['notes'][0]['id'])")
echo "NID=$NID"
curl -sS "${H[@]}" -X PUT "$API/notes/$NID" -d '{"name":"renamed"}'; echo
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${H[@]}" -X PUT "$API/notes/$NID" -d '{"content":"replaced"}'
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${H[@]}" -X DELETE "$API/notes/$NID"

say "9. note without notebook_id (record placement; observed notebook_id null)"
curl -sS "${H[@]}" -X POST "$API/notes" -d '{"name":"no notebook","content":"x","source":"noctalia","source_id":"smoke-n2"}'; echo
NID2=$(curl -sS "${H[@]}" "$API/notes?source=noctalia&source_id=smoke-n2" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['notes'][0]['id'])")
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${H[@]}" -X DELETE "$API/notes/$NID2"

say "10. journal: two entries same date (record; observed: both accepted)"
TODAY=$(date +%F)
curl -sS "${H[@]}" -X POST "$API/journal_entries" -d "{\"date_on\":\"$TODAY\",\"content\":\"smoke test entry\"}"; echo
curl -sS "${H[@]}" -X POST "$API/journal_entries" -d "{\"date_on\":\"$TODAY\",\"content\":\"second entry, same date\"}"; echo

say "11. bad token (expect 401)"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -H "Authorization: bearer nope" "$API/ping"

echo "DONE. Remember: delete the two journal entries for $TODAY in the Lunatask app."
