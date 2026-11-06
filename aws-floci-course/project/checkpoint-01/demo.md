# USMS - Demonstration script, Checkpoint 1

Eight minutes. Commands first, one sentence to say while each runs. Run the whole thing once in
the room before the actual slot - a stale window or a sleeping Floci container is the most common
reason a demo that worked last night does not work now.

## 0-1 min - inventory

```bash
cd ~/aws-floci-course
source configs/course.env
./scripts/utilities/usms-project-inventory.sh | tee project/checkpoint-01/inventory.txt
```

**Say:** "This is one script that describes the whole system - every lab's resources, plus the
result of every verify script, regenerated fresh right now rather than pasted from last week."

## 1-4 min - the nine-stage end-to-end path, live

```bash
export MSYS_NO_PATHCONV=1
AWS="aws --endpoint-url $FLOCI_ENDPOINT"

./scripts/utilities/whoami.sh
$AWS iam list-attached-role-policies --role-name usms-lambda-exec-role --query 'AttachedPolicies[].PolicyName' --output text

$AWS s3api head-bucket --bucket usms-student-data && echo "bucket reachable"
$AWS s3api get-bucket-notification-configuration --bucket usms-student-data --query 'LambdaFunctionConfigurations[].[Id,LambdaFunctionArn]' --output text

$AWS lambda get-function-configuration --function-name usms-transcript-notifier --qualifier live --query '[Version,Runtime,TracingConfig.Mode]' --output text

./scripts/utilities/usms-emit-telemetry.sh science 0.63

$AWS logs filter-log-events --log-group-name /usms/central/application --filter-pattern 'USMS_EVENT' --query 'events[-1].message' --output text

$AWS cloudwatch list-metrics --namespace USMS/Application --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u

$AWS cloudwatch describe-alarms --query 'MetricAlarms[].[AlarmName,StateValue,TreatMissingData]' --output text
```

**Say, stage by stage, as each runs:** "Identity - this is who I am and what my Lambda role may
do. Storage - the bucket exists, and its notification is wired straight to the live alias of the
notifier, not a specific version. Compute - version 4 of the notifier, with active tracing on.
Now I upload a transcript - " *(let the emitter run)* " - and here's the log line it wrote, with a
trace ID I can correlate. Here are the five real custom metrics in the namespace it just
contributed to. And here are the two alarms watching them, both correctly configured, one proven
earlier today by forcing a real state transition."

**Do not read `evidence/end-to-end.txt` here** - run it live. The captured file is the fallback if
something in the room genuinely breaks, not the primary demonstration.

## 4-6 min - one thing I understand well

**Choice: the Lambda version/alias mechanism, and what it revealed.**

```bash
$AWS lambda list-versions-by-function --function-name usms-transcript-notifier --query "Versions[?Version!='\$LATEST'].[Version,Description]" --output table

$AWS lambda get-alias --function-name usms-transcript-notifier --name live

echo "--- CodeSha256 across versions, which should differ and do not on this build ---"
for v in 1 3 4; do
  $AWS lambda get-function --function-name usms-transcript-notifier --qualifier "$v" --query 'Configuration.CodeSha256' --output text
done
```

**Say:** "Every piece of this system that triggers the notifier - the bucket notification, the
resource policy allowing S3 to invoke it - points at this one alias, never a function ARN or a
version number directly. Lab 13 repointed it from the original handler to an instrumented one, and
then again to add tracing, and nothing else in the system needed to change. But watch this -" *(run
the CodeSha256 loop)* " - on real AWS those three hashes would all differ, because publishing a
version is supposed to freeze an immutable snapshot. Here they're identical. I found this by doing
exactly the rollback exercise the lab guide asks for, expecting version 1 to lack a field the new
code added, and it didn't lack it - which is what led me to check the hashes and find the actual
gap underneath the one I was looking for."

## 6-8 min - questions

Two standard questions, answerable from `gaps.md` without improvising:

**"Show me something in your system that does not work, and tell me how you know."**
→ Point at the X-Ray row in `gaps.md`'s "Unavailable" section: every `xray:*` call returns
`UnknownOperationException` on this build - not a timeout, not a permissions error, a route that
does not exist. Show `templates/lab-13-segment-parent.json` and its structural-validation output
(11/11 checks) as what was built instead, and say plainly that it was never sent anywhere.

**"If I changed one thing to break this, what would you have me change?"**
→ The bucket's event notification configuration (`s3api put-bucket-notification-configuration`
with an empty `LambdaFunctionConfigurations` list). Nothing in IAM would object - it is not a
permissions change, it is removing the one piece of resource-level wiring, with no IAM
representation at all, that turns "an object was uploaded" into "a function ran." It is also
exactly the dependency `architecture.md`'s trust-boundary table flags as the one students most
often miss.
