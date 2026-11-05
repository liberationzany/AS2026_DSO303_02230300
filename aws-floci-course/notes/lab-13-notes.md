# Lab 13 notes - Centralized Logging and Monitoring with CloudWatch and X-Ray

## Support surface on this build

Step 4's probe (`outputs/lab-13-support-probe.txt`) was run as *direct write-operation tests*,
not just read calls, because the read calls alone were ambiguous. The confirmed result is
narrower than the lab's "typical" scenarios, which generally assume at least one of metric
filters / Logs Insights / X-Ray works on a given build:

- **Genuinely supported**: log groups/streams/events (full CRUD + retention), custom metrics
  (`put-metric-data`/`list-metrics`/`get-metric-statistics`), metric alarms (`put-metric-alarm`,
  `describe-alarms`, `set-alarm-state`).
- **Entirely unsupported** (`UnsupportedOperation` or `UnknownOperationException`, confirmed by
  attempting the write call directly, not inferred from a read failing): `put-metric-filter`,
  `describe-metric-filters`, `test-metric-filter` (even the pure-function read-only test),
  Logs Insights (`describe-queries`/`start-query`), `put-dashboard`/`list-dashboards`,
  `put-composite-alarm`, `describe-alarm-history`, and the **whole X-Ray service**
  (`get-sampling-rules`, `get-service-graph`, `put-trace-segments` all return
  `UnknownOperationException` - the routes do not exist at all, not merely storage-only).

Every step below that needed one of these was adapted: the two metric filters were written as
documents (`templates/lab-13-metric-filters.json`) with their target metrics populated by hand
instead of firing; the three X-Ray segment documents and the sampling rule were validated
structurally only; the composite alarm and the dashboard were written and JSON-validated but
never applied.

## A real MSYS path-mangling bug, caught and fixed

The very first `create-log-group --log-group-name /usms/central/application` call silently
created a log group named `C:/Program Files/Git/usms/central/application` instead - Git Bash's
MSYS layer auto-converted the POSIX-style path-looking string into a Windows path when it was
passed as a standalone argv token to `aws.exe` (a native, non-MSYS binary). This is the same
class of bug documented in earlier labs for Python `-c` script bodies, but this is the first
time it hit a plain CLI argument directly. Fixed by exporting `MSYS_NO_PATHCONV=1` for the rest
of the session (and inside `usms-emit-telemetry.sh`, which needs it for every `logs` call); the
mangled group was deleted once the fix was confirmed.

A second-order consequence: with `MSYS_NO_PATHCONV=1` set, `mktemp`'s own `/tmp/...` output
stopped resolving for the native-Windows Python interpreter inside
`usms-emit-telemetry.sh` (the same path no longer gets silently translated). Fixed by using a
repo-relative temp file (`outputs/.tmp/emit-telemetry-log-events.json`) instead of `mktemp`,
consistent with this repo's established "prefer repo-relative paths over `/tmp`" rule.

## Step 7/8/9 - the filter patterns (tested by inspection, since `test-metric-filter` is absent)

`USMS_NOTIFY` matches none of Step 7's five log lines (correctly - it is meant to match only the
real notifier's own marker, confirmed separately: a real `usms-transcript-notifier` invocation
genuinely wrote 7 `USMS_NOTIFY` lines into its own log group, found via `filter-log-events`).

`ERROR` correctly matches Step 7's fourth line (`ERROR USMS_EVENT {...}`) and nothing else
among the five - but Step 8's own false-positive probe shows a real production problem: the
plain-text line `USMS_EVENT {"event":"transcript.processed","reason":"no ERROR here"}` also
matches, because the filter dialect does whitespace-token matching anywhere in the line, not
anchored to a severity marker. A correct production pattern would need to anchor on the literal
two-token sequence `ERROR USMS_EVENT` (ERROR first), which this lab's deployed pattern does not
do. Full reasoning is in `templates/lab-13-metric-filters.json`.

## Lambda versions are not immutable on this build - a significant finding

Step 13's "Your turn" (roll back to version 1, confirm `trace_id` is absent, roll forward) found
the opposite of what it expected: version 1's response **still had a `trace_id` field**, even
though the field only exists in the Lab 13-authored handler, never in Lab 10's original code.
Checking `CodeSha256` across versions 1, 2, 3 and `$LATEST` showed **all four report the
identical hash**. On real AWS, `publish-version` freezes an immutable code snapshot; on this
build it does not - every published version resolves to whatever code the function's storage
currently holds, so `update-function-code` silently rewrites every prior version at once. This
undermines the entire "a version freezes code so rollback is instant" guarantee Lab 10 Step 11
relied on, and is a materially bigger gap than the usual "stored but not enforced" pattern: here
the thing that is supposed to make rollback *possible at all* does not hold.

## Step 19/20 - CloudWatch alarms: accepted but not echoed back

`put-metric-alarm` accepted every parameter (`--treat-missing-data`, `--datapoints-to-alarm`,
`--unit`, `--dimensions`, `--tags`) with no error, but `describe-alarms` on this build returns
only `AlarmName`, `AlarmArn`, `AlarmDescription`, `ActionsEnabled`, `StateValue`, `MetricName`,
`Namespace`, `Statistic`, `Period`, `EvaluationPeriods`, `Threshold` and `ComparisonOperator` -
silently omitting `TreatMissingData`, `DatapointsToAlarm`, `Unit`, `Dimensions` and `Tags`
entirely from the response. This is a stricter instance of the "accept but drop" pattern found
repeatedly elsewhere (ECR control-plane blindness in Lab 12, `LambdaFunctionAssociations`
dropped from CloudFront in Lab 10): here the *read* API is thinner than the *write* API accepted,
not merely un-enforced. `templates/lab-13-alarms.json` records the intended configuration (the
`notBreaching`/`breaching` distinction Step 19 is actually about) since the API cannot prove it
after the fact.

Step 20's forced transition genuinely worked: `set-alarm-state --state-value ALARM` moved
`usms-transcript-lag-high` from `OK` to `ALARM` and the state read back correctly - but
`StateReason` was `null` on read-back (the reason text was accepted, not echoed), and
`describe-alarm-history` is itself `UnsupportedOperation`, so the history-recording half of the
proof could not be completed. Recorded in `outputs/lab-13-alarm-history.json`.

## Step 24 - full persistence proof

Floci was stopped and restarted (`floci-down.sh` / `floci-up.sh`). Every log group (with its
retention), all five metrics in `USMS/Application`, both alarms with their states, and the
notifier's `live` alias (version 4, tracing `Active`) were byte-for-byte identical before and
after (`diff outputs/lab-13-pre-restart.txt outputs/lab-13-post-restart.txt` reported no
differences). Metric **data** also survived (1 `TranscriptsProcessed` data point before and
after the restart over the same window) - unlike some other labs' findings, this build does not
lose time-series data across a restart.

## Review Questions

**1. "We have logs, so we do not need metrics" - the two strongest arguments against, and the
one situation where the colleague is right.**

First, cost and speed of the question you can ask. A log line is cheap to write and expensive to
re-read in bulk: answering "how many transcripts failed in the last hour" from logs means
scanning every event (this lab's own Path B for Logs Insights did exactly that, in Python, over
a few dozen lines - it does not scale to production volume). A metric is the opposite trade: it
costs a little at write time (an extra API call, or a filter evaluated at ingestion) and is then
cheap to query at any granularity, instantly, forever (well, fifteen months - Section 11).
Second, what each is *for*: a log line is one event's full detail; an alarm needs a single
number crossing a threshold. CloudWatch cannot alarm directly on logs (the log layer has no
`StateValue`), only on a metric, so "we have logs" cannot by itself produce a page - it requires
a human to be reading them, or a metric derived from them, which is the whole reason Step 9's
filters exist. The one situation where the colleague is right: a system with genuinely low
event volume and no on-call requirement, where someone really does read every log line by hand
and a metric would be pure overhead - which is approximately never true past a handful of users,
but is not false in principle.

**2. Metric filter (Step 9) versus a direct `put-metric-data` call (Step 11) - retroactivity,
cost, what must change to add a measurement, and what happens when the emitting code is not
yours; which for "how many downloads" and which for "how long the render took".**

A metric filter runs at ingestion only - it is not retroactive (confirmed in this lab: Step 9's
own warning, and the lab's note that last week's logs need Insights, not a new filter). A direct
`put-metric-data` call has no such restriction; it just needs correct data to publish, whenever
you call it. Cost: both are billed per metric produced, but a filter is "free to read" in the
sense that nothing in the application has to change or know about CloudWatch - it is a pure
side effect of writing a log line that was going to be written anyway. A direct call requires
the application to hold IAM permission, import a client library, and spend a network round trip
inside the request path (or accept the risk of failure, which this lab's `publish()` function
explicitly guards against). To add a new measurement: a filter needs a new filter definition
(infrastructure change, no code change) as long as the log line already carries the right
field; a direct call needs a code change (a new `put_metric_data` call) every time. And the
sharpest distinction: when the emitting code is not yours (a third-party library, a managed
service's own logs), a metric filter is the *only* option - you cannot add a `put_metric_data`
call to code you do not control, but you can always attach a filter to whatever it logs.

For "how many transcript downloads happened" - a pure count, a stable marker string, code you
may or may not own - a filter (`usms-notify-count`) is the natural fit: it is a count of a
distinguishable event, needs no extra application logic, and would work even if the notifier
were a third-party function. For "how long the render took" - a continuous value computed
inside your own code, where you already have the number in hand at the point of measurement -
a direct `put-metric-data` call (`TranscriptLagSeconds`) is simpler and more precise: the
alternative (extracting a numeric field from a log line via the filter's JSON dialect) adds a
layer of text-matching risk for a value you already hold as a Python float. The answers differ
because one question is "did an event of this shape happen" (a filter's natural job) and the
other is "what was the value of something you already computed" (a direct call's natural job).

**3. Why `notBreaching` would be wrong on `usms-notify-silence` and `breaching` would be wrong
on `usms-transcript-lag-high`; an incident the second alarm catches that the first cannot; what
the dashboard would have shown during it.**

`usms-transcript-lag-high` watches a *value* (how long a notification took) that genuinely has
no data at 3am because nothing is running - silence there is the expected, healthy state, so
`notBreaching` (ignore the gap, keep the last real state) is correct; `breaching` on this alarm
would page someone every quiet night for doing nothing wrong. `usms-notify-silence` watches
*whether events are happening at all* - for this alarm, the absence of data **is** the signal
being watched for, so `notBreaching` would make the alarm permanently inert (a metric that
never gets a data point can never breach a "missing is fine" policy, so an entirely broken
pipeline would sit there quietly reporting nothing was wrong, which is exactly the six-hour
outage scenario the lab's own project-appendix complaint describes).

The incident: the upload-to-S3 step itself breaks (a bucket policy change, a notification
misconfiguration, the notifier's execution role losing a permission) so the notifier never runs
at all. `TranscriptLagSeconds` never gets a data point either way, so `usms-transcript-lag-high`
(watching a *value*) has nothing to evaluate and sits in `notBreaching`'s safe default forever -
it cannot distinguish "nothing happened because nothing is happening right now" from "nothing
has happened in fifteen minutes and that itself is wrong", because it was never designed to
watch for absence. `usms-notify-silence`, watching `NotifyCount`'s absence directly with
`breaching`, is the only one of the two that can fire. During that incident, the dashboard
(Step 22's widgets) would have shown exactly nothing: the `TranscriptsProcessed` and
`TranscriptLagSeconds` time-series panels would simply stop drawing new points and look like a
flat, empty, unremarkable gap - indistinguishable at a glance from a quiet night - which is the
literal mechanism behind the project appendix's "the dashboard was all green because the graphs
were empty" complaint. Only the alarm widget, if `usms-notify-silence` actually fired, would
show anything was wrong.

**4. Metric dimension versus X-Ray annotation: what each is indexed for, what happens as
distinct values grow, what you can ask of each; placing four fields.**

A metric dimension is part of the metric's *identity* - namespace + name + the complete
dimension set defines one time series (Step 11). It is indexed for aggregation: "sum this value
across all dimension combinations" or "show me this one combination's trend over time". Each
distinct combination of dimension values is a **separate billed metric**, so as the number of
distinct values grows, the number of metrics grows multiplicatively with it - this is the
cardinality-is-cost problem Step 11 names explicitly. An X-Ray annotation is indexed for
*search*: "find me every trace where this annotation equals this value" (Step 17's filter
expressions), one trace document at a time. It does not multiply anything - adding more distinct
annotation values does not create more metrics, it just makes the search index larger, because
a trace is not an aggregate, it is a single request's record.

Placement: the transcript's **faculty** (a small, fixed set, maybe eight values) belongs in a
metric dimension - exactly what this lab does with `TranscriptsProcessed{Faculty=...}` - because
you genuinely want an aggregate count per faculty over time. The **student's id** (tens of
thousands of values) belongs in neither a metric dimension (would create tens of thousands of
billed metrics) nor casually in a log field without thought, but if it needs to be searchable
per-request it is exactly what an X-Ray annotation is for - searching "show me this one
student's trace" costs nothing extra per distinct value, unlike a dimension. The **origin's HTTP
status** (a small set: 200, 403, 404, 500...) is a reasonable annotation (searchable, and you
would want to filter traces by it) or could be a dimension if you specifically want an
aggregate error-rate metric by status - both are defensible, which is why this lab's own
`downstream` segment put it in `http.response.status` rather than either, since X-Ray natively
derives ok/error/fault classification from that field without it needing to be a separate
annotation at all. The **name of the renderer that produced the PDF** (a handful of values, but
not something you would ever want to alarm on or chart as a time series) belongs in metadata,
not an annotation or a dimension - it is useful to see when looking at one trace, never useful
to search or aggregate by, which is exactly metadata's job (unsearchable, arbitrary JSON) as
distinct from an annotation's job (searchable, scalar).

**5. Why Step 14's tracing-only change needed its own version, and what would have happened
leaving the alias on version 2.**

A Lambda version freezes code *and* configuration together (Lab 10 Step 11's rule). Tracing
mode is configuration, not code - `TracingConfig` lives alongside the function, not inside the
zip - but the freezing rule does not distinguish between the two: whatever `update-function
-configuration` last set becomes part of whatever gets published next. If the `live` alias had
stayed on version 2 after Step 14's `update-function-configuration --tracing-config Mode=Active`
call, the alias would still be invoking version 2's frozen configuration, which is whatever
`TracingConfig` was in effect *when version 2 was published* (`PassThrough`, from before Step
14) - the live, trigger-facing function would never actually run with active tracing, even
though the account-level setting had been changed. This is exactly what this lab's own Lambda
version finding (above) undermines on this specific build - since `publish-version` does not
actually freeze a code snapshot here - but the *configuration* half of the freeze behaved as
designed: Step 14 correctly required a new published version (4) and a fresh alias repoint to
make the live-facing function actually trace, which is the real-AWS-faithful part of the lesson
even though the code-immutability part was not.

**6. What Step 20's forced transition proves and does not prove; what an equivalent real-AWS
test would additionally prove; why test what happens after an alarm fires even when confident in
the threshold.**

It proves the alarm *object* is correctly wired: its name is addressable, a state change is
accepted and genuinely persists (`StateValue` read back as `ALARM`, confirmed), and - on a build
that supports it - the transition would be recorded in history for later audit. It does **not**
prove the alarm will ever reach `ALARM` on its own: nothing about `set-alarm-state` touches the
evaluation logic that would normally compare `TranscriptLagSeconds` against the threshold every
period. On real AWS, the equivalent test (publishing real metric data that genuinely crosses
the threshold, then waiting for CloudWatch's own evaluation cycle) would additionally prove the
evaluation pipeline itself works end to end: that the statistic, period, evaluation-periods and
datapoints-to-alarm configuration actually produces a breach from real data, and - the part this
lab could not reach at all on this build - that `--alarm-actions` genuinely fires whatever is
attached (an SNS publish, in a future lab). The reason to test what happens *after* an alarm
fires, even when confident in the threshold math, is the general rule this whole course keeps
re-deriving under different names: a command returning success, or a configuration looking
correct on paper, is not evidence it does what you meant - the only way to know an alarm will
actually notify someone is to watch it notify someone, once, deliberately, the way Step 20 does
for the state transition and a real alerting lab would need to do for the action.
