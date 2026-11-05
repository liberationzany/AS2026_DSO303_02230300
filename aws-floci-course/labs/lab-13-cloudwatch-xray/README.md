# Lab 13 - Centralized Logging and Monitoring with CloudWatch and X-Ray

Support surface on this build, confirmed by direct write-operation tests (not inferred from a
read call): real log groups/streams/events with retention, real custom metrics
(`put-metric-data`/`list-metrics`/`get-metric-statistics`), and real metric alarms
(`put-metric-alarm`/`describe-alarms`/`set-alarm-state`). **No** metric filters, **no** Logs
Insights, **no** CloudWatch dashboards, **no** composite alarms, and **no** X-Ray at all
(`UnknownOperationException` on every `xray:*` call - the service is entirely unrouted). Full
detail in `outputs/lab-13-support-probe.txt`.

## What this lab built

- `/usms/central/application` (30-day retention) created; retention set on every other USMS
  log group that was still on never-expire (`/usms/ecs/enrolment`, both notifier log groups).
- Five structured `USMS_EVENT`/`ERROR` log lines written with correct millisecond timestamps,
  plus a non-matching health-check line as the negative-case probe.
- Two metric filter *definitions* (`templates/lab-13-metric-filters.json`) - `put-metric-filter`
  is unsupported, so these were never created live. Their pattern correctness was checked by
  hand against the five log lines and a deliberate false-positive probe (documented reasoning
  in the same file); their target metrics (`NotifyCount`, `CentralErrorCount`) were populated
  directly with `put-metric-data`, using real observed counts (7 real `USMS_NOTIFY` lines from
  a genuine notifier invocation, 1 real error line).
- Five custom metrics in `USMS/Application`, including `TranscriptsProcessed` published both
  with dimensions and as an undimensioned total.
- `USMSObservabilityWrite` created and attached to both `usms-lambda-exec-role` and
  `usms-ec2-app-role`, alongside their existing policies.
- `usms-transcript-notifier` instrumented (version 3) then traced (version 4, `TracingConfig
  Mode=Active`); `live` alias repointed to each in turn.
- X-Ray segments, subsegments and a sampling rule written as documents
  (`templates/lab-13-segment-*.json`, `templates/lab-13-sampling-rule.json`) and validated
  structurally (11/11 checks pass) - never sent, since the service does not exist here.
- `usms-transcript-lag-high` and `usms-notify-silence` metric alarms created live, with a
  forced state transition proving `set-alarm-state` genuinely works
  (`outputs/lab-13-alarm-history.json`).
- `usms-transcript-pipeline-down` (composite) and `usms-overview` (dashboard) written and
  JSON-validated (`templates/lab-13-composite-alarm.json`, `templates/lab-13-dashboard.json`)
  but never applied - both APIs are unsupported.
- `scripts/utilities/usms-emit-telemetry.sh`: emits a log line, two metric data points, and
  attempts a trace segment (honestly reporting `SKIPPED` on this build), run three times.
- Full restart persistence proof: `floci-down.sh`/`floci-up.sh`, then every object (log groups
  with retention, all five metrics, both alarms with state, the notifier's alias and tracing
  mode) came back byte-for-byte identical, and metric *data* also survived.

## Two significant findings beyond the usual "stored, not evaluated" pattern

1. **Lambda versions are not immutable on this build.** `publish-version` does not freeze a
   code snapshot - `CodeSha256` was identical across versions 1, 2, 3 and `$LATEST` after
   deploying the instrumented code, so rolling the `live` alias back to "version 1" still ran
   the new handler. `update-function-code` appears to rewrite every published version at once.
   This undermines the rollback guarantee Lab 10's whole alias/version design depends on.
2. **`describe-alarms` is thinner than `put-metric-alarm` accepted.** `--treat-missing-data`,
   `--datapoints-to-alarm`, `--unit`, `--dimensions` and `--tags` are all silently absent from
   the read response, even though the create call accepted them without error - a stricter
   case of the "accept but drop" pattern than usual, since it's the *read* API that's thinner,
   not just unenforced evaluation. The intended configuration is recorded in
   `templates/lab-13-alarms.json` since the API cannot prove it afterward.

A genuine MSYS/Git-Bash path-mangling bug was also caught and fixed: `/usms/central/application`
was silently converted to a Windows path on its first use as a plain CLI argument. Fixed with
`MSYS_NO_PATHCONV=1` (and a repo-relative temp file in the emitter script, since that same fix
broke `mktemp`'s own `/tmp` path for native Windows Python).

## Verification

`scripts/utilities/verify-lab-13.sh`: **PASS=49 FAIL=0**. See the script for how each
unsupported-feature check was adapted to verify the document this lab produced instead of a
live object that does not exist here.
