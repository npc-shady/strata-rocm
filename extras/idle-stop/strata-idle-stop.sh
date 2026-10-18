#!/bin/bash
# strata-idle-stop.sh [--dry-run] -- run every minute by strata-idle-stop.timer.
# Stops the Strata container once it has been idle for IDLE_MIN minutes, so the GPU
# can power down (or be used by something else). With the wake proxy installed,
# the next model request starts it again; otherwise: docker start strata.
#
# Idle = Strata's /metrics shows live.state "idle" with nothing queued AND no request
# ended in the last IDLE_MIN minutes (requests[].time + duration_s; totals.since
# before the first request). Anything unreadable counts as busy, so it never stops
# Strata mid-job or while it is still loading.
#
# Settings (environment, or /etc/default/strata-idle-stop):
#   STRATA_CONTAINER  container name                 (strata)
#   STRATA_URL        the container's port, NOT the proxy's, so checks never wake it
#                                                    (http://127.0.0.1:18081)
#   STRATA_KEY_FILE   file holding the API key       (/etc/strata-api-key)
#   IDLE_MIN          minutes idle before stopping   (30)
#   WINDOW            hours it may stop in, "23-9"; empty = any time   (empty)
#   TZ                time zone for WINDOW           (the system's)
set -u
STRATA_CONTAINER=${STRATA_CONTAINER:-strata}
STRATA_URL=${STRATA_URL:-http://127.0.0.1:18081}
STRATA_KEY_FILE=${STRATA_KEY_FILE:-/etc/strata-api-key}
IDLE_MIN=${IDLE_MIN:-30}
WINDOW=${WINDOW:-}
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
log(){ echo "strata-idle-stop: $*"; }
busy(){ [ $DRY = 1 ] && log "busy: $*"; exit 0; }

in_window(){
  [ -z "$WINDOW" ] && return 0
  local s=${WINDOW%-*} e=${WINDOW#*-} h; h=$(date +%-H)
  if [ "$s" -le "$e" ]; then [ "$h" -ge "$s" ] && [ "$h" -lt "$e" ]
  else [ "$h" -ge "$s" ] || [ "$h" -lt "$e" ]; fi
}

[ "$(docker inspect -f '{{.State.Running}}' "$STRATA_CONTAINER" 2>/dev/null)" = true ] || busy "not running"
key=$(cat "$STRATA_KEY_FILE" 2>/dev/null) || busy "key file $STRATA_KEY_FILE unreadable"
m=$(curl -sf -m 5 -H "Authorization: Bearer $key" "$STRATA_URL/metrics") || busy "/metrics not answering (loading?)"
read -r state queued idle < <(printf '%s' "$m" | python3 -c 'import sys,json,time
d=json.load(sys.stdin); l=d.get("live") or {}
ends=[r["time"]+(r.get("duration_s") or 0) for r in d.get("requests") or [] if r.get("time")]
last=max(ends) if ends else d["totals"]["since"]
print(l.get("state","?"), l.get("queued","?"), int((time.time()-last)//60))') || busy "/metrics unparseable"
if [ "$state" != idle ] || [ "$queued" != 0 ]; then busy "$state, $queued queued"; fi
in_window || busy "idle $idle min, outside WINDOW $WINDOW"
[ "$idle" -ge "$IDLE_MIN" ] || busy "idle $idle of $IDLE_MIN min"
if [ $DRY = 1 ]; then log "would stop $STRATA_CONTAINER now (idle $idle min)"; exit 0; fi
docker stop -t 120 "$STRATA_CONTAINER" >/dev/null && log "stopped $STRATA_CONTAINER after $idle min idle"
