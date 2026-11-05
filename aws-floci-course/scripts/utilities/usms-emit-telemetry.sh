#!/usr/bin/env bash
# Emit one of each USMS telemetry signal - a log event, a metric data point and
# a trace - describing the same fictional transcript, so that the three can be
# joined afterwards by trace id.
#
# Usage: usms-emit-telemetry.sh [faculty] [seconds]
# Writes: appends to outputs/lab-13-trace-ids.txt
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export MSYS_NO_PATHCONV=1
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-13.env" 2>/dev/null || true

FACULTY="${1:-science}"
SECONDS_TAKEN="${2:-0.42}"
GROUP="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
NAMESPACE="${USMS_METRIC_NAMESPACE:-USMS/Application}"
STREAM="emitter-$(date -u +%Y%m%d)"

IDS=$(python -c "
import os, time
now = time.time()
print('1-%08x-%s' % (int(now), os.urandom(12).hex()), os.urandom(8).hex(), int(now*1000), now)
")
TRACE_ID=$(printf '%s' "$IDS" | awk '{print $1}')
SEG_ID=$(printf '%s' "$IDS" | awk '{print $2}')
NOW_MS=$(printf '%s' "$IDS" | awk '{print $3}')
NOW_S=$(printf '%s' "$IDS" | awk '{print $4}')

aws logs create-log-stream --log-group-name "$GROUP" --log-stream-name "$STREAM" 2>/dev/null || true

mkdir -p outputs/.tmp
LOGFILE="outputs/.tmp/emit-telemetry-log-events.json"
python - "$NOW_MS" "$FACULTY" "$SECONDS_TAKEN" "$TRACE_ID" "$LOGFILE" << 'PY'
import json, sys
now_ms, faculty, secs, trace_id, path = sys.argv[1:]
msg = 'USMS_EVENT ' + json.dumps({"event": "transcript.processed", "faculty": faculty,
                                   "seconds": float(secs), "trace_id": trace_id})
json.dump([{"timestamp": int(now_ms), "message": msg}], open(path, "w"))
PY
aws logs put-log-events \
  --log-group-name "$GROUP" --log-stream-name "$STREAM" \
  --log-events "file://$LOGFILE" \
  --query 'rejectedLogEventsInfo' --output json >/dev/null \
  && echo "  log    ok   $GROUP"
rm -f "$LOGFILE"

aws cloudwatch put-metric-data \
  --namespace "$NAMESPACE" \
  --metric-data "MetricName=TranscriptsProcessed,Unit=Count,Value=1,Dimensions=[{Name=Faculty,Value=$FACULTY},{Name=Stage,Value=notify}]" \
                "MetricName=TranscriptLagSeconds,Unit=Seconds,Value=$SECONDS_TAKEN,Dimensions=[{Name=Stage,Value=notify}]" \
  && echo "  metric ok   $NAMESPACE"

SEGMENT=$(python - "$TRACE_ID" "$SEG_ID" "$NOW_S" "$FACULTY" "$SECONDS_TAKEN" << 'PY'
import json, sys
trace_id, seg_id, now, faculty, secs = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], float(sys.argv[5])
print(json.dumps({
    "name": "usms-transcript-notifier",
    "id": seg_id,
    "trace_id": trace_id,
    "start_time": round(now - secs, 3),
    "end_time": round(now, 3),
    "origin": "AWS::Lambda::Function",
    "annotations": {"faculty": faculty, "stage": "notify", "emitted_by": "usms-emit-telemetry"},
}))
PY
)
if aws xray put-trace-segments --trace-segment-documents "$SEGMENT" \
    --query 'UnprocessedTraceSegments' --output text >/dev/null 2>&1; then
  echo "  trace  ok   $TRACE_ID"
else
  echo "  trace  SKIPPED (X-Ray unavailable on this build) $TRACE_ID"
fi

printf '%s %s emitter/%s\n' "$TRACE_ID" "$SEG_ID" "$FACULTY" >> outputs/lab-13-trace-ids.txt
echo
echo "trace id: $TRACE_ID"
