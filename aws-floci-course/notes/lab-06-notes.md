# Lab 06 notes

## Step 3 support path

**Path C — no Application Auto Scaling.** `aws application-autoscaling
describe-scalable-targets --service-namespace ecs` — a call that should return an
empty list successfully when nothing is registered — instead returned
`UnknownOperationException: Unknown operation: AnyScaleFrontendService.DescribeScalableTargets`.
The same exception was confirmed for `put-scaling-policy`,
`describe-scheduled-actions`, and `describe-scaling-activities`: this build's
Floci server does not implement the Application Auto Scaling backend at all,
categorically, not as an empty-but-working service. Per the guide's own Path C
instructions: no scalable target, scaling policy, or scheduled action exists on this
build for real. What follows is everything that genuinely is real (CloudWatch's
custom metric and alarm — a separate backend that does work), the designed
configuration documents (written as artefacts even though they can't be submitted to
a live API), and the conceptual/paper work Path C calls for, including Exercise 4's
capacity plan below.

Two further, independently confirmed data points:
- `aws iam create-service-linked-role --aws-service-name
  ecs.application-autoscaling.amazonaws.com` returned a *different* error,
  `UnsupportedOperation: Operation CreateServiceLinkedRole is not supported` — a
  known IAM operation this build simply hasn't implemented, distinct from the
  Application Auto Scaling backend being entirely absent.
- `aws cloudwatch set-alarm-state --alarm-name usms-enrolment-queue-high
  --state-value ALARM` genuinely worked and moved the alarm's `StateValue`. The
  alarm mechanism functions right up to the exact boundary where it would hand off
  to Application Auto Scaling — which is precisely where this build's capability
  ends, and a clean, specific place to draw the line in a report.

## Review questions

**1. The nine-line chain from Step 15, and why the other six lines needed no modification.**

The nine-line chain, with this lab's three lines marked:

1. A student clicks Register.
2. Requests per target rises past 1000, or the work queue passes 100. **(this lab)**
3. An alarm fires and invokes a policy. **(this lab)**
4. The policy writes `desiredCount`, clamped to 2..10. **(this lab)**
5. ECS starts a task from `usms-enrolment:2`.
6. The task gets an ENI in `usms-private-subnet-a` or `-b`, no public address.
7. `usms-enrolment-sg` admits tcp/80 from `usms-alb-sg` only.
8. The service registers its address in `usms-enrolment-tg`.
9. The load balancer health-checks it; after 60s of grace it takes traffic.

Lines 5–9 needed no modification because they are properties of objects Labs 02, 04
and 05 already built and that this lab never touches: the task definition, the
subnets, the security group, the service's `loadBalancers` entry, and the target
group's health check are all exactly as Lab 05 left them. Auto scaling's entire
contribution is deciding *when* and *to what number* `desiredCount` changes — it has
no mechanism for starting a container, assigning it a network interface, or routing
traffic to it, because ECS, the VPC, and the load balancer already do all three and
auto scaling was never going to duplicate them. The one-sentence answer to "what does
auto scaling change about my application?" is: **nothing — it changes how many copies
of it there are.**

**2. Why a constructed resource ID rather than an ARN, and the other three constructed identifiers in this architecture.**

Application Auto Scaling is one generic API sitting in front of nine different AWS
services, each of which names its own resources in its own way — a DynamoDB table, a
Lambda alias, an ECS service. A single ARN format cannot express all nine shapes
uniformly in a way the generic API could parse without namespace-specific logic, so
each service namespace instead defines a small, documented string grammar:
`service/<cluster>/<service>` for `ecs`, `table/<name>` for `dynamodb`,
`function:<name>:<alias>` for `lambda`. For ECS specifically, that resource ID is not
arbitrary — it is defined to be exactly the final colon-separated segment of the
service's own ARN, which is why `"${SVC_ARN##*:}"` is the correct and sufficient way
to build it, and why passing the whole ARN is rejected: the API is looking for a
much narrower string than the one most people reach for first. The other three
constructed identifiers this architecture has produced: the ECS control-plane pair
`--cluster <name> --service <name>` (Lab 04); the ELB `ResourceLabel`
(`app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>`, built from fragments of two
different ARNs, Step 9 of this lab); and the ECS tagging ARN form used by
`tag-resource` calls. All four exist because a human-readable name and a
machine-addressable identifier are different problems, and each AWS service has
solved the second one slightly differently.

**3. Registering a scalable target below its minimum, versus a scaling policy — and a 3am scenario.**

Registering a scalable target with `--min-capacity 2` against a service already
running fewer than 2 tasks raises `desiredCount` immediately, as a direct, synchronous
consequence of the registration call itself — the **scalable target** (specifically,
the act of registering it) made that change, not a scaling policy and not an alarm.
This differs from a scaling policy's change in an important way: a policy's decision
is always traceable to a metric crossing a threshold, recorded with a `Cause` string
naming the alarm and the policy; a registration's capacity bump has no such trail
beyond the registration call itself. The 3am scenario: an on-call engineer, trying to
ride out an incident, re-registers the target with `--min-capacity 5` to guarantee
headroom, then goes to bed without telling anyone. Nothing alerts the next shift.
The evidence that would reveal it is `describe-scalable-targets`'
`MinCapacity`/`CreationTime` fields — not a scaling activity, since none was created —
so the person taking over at eight has to think to check the registration itself,
not the activity log, to notice the floor was moved.

**4. AWS-managed alarms vs. your own alarm — ownership, policy-change behavior, deletion, and TreatMissingData.**

A target tracking policy's two managed alarms are owned, created, and reconciled by
Application Auto Scaling itself: changing the policy's `TargetValue` or cooldowns
causes AWS to rebuild the alarms to match, and deleting the policy deletes them with
it. The alarm this lab wrote by hand is owned by the operator: nothing rebuilds it if
its threshold is wrong, and nothing deletes it when the step policy it drives is
deleted — "nothing deletes it for you, because nothing created it for you" is exactly
symmetric. The one thing a hand-written alarm can do that a managed one cannot:
`AlarmActions` is a generic field that can point at an SNS topic or any other
action type alongside (or instead of) a scaling policy, so the same alarm that scales
the service can also page a human — a managed alarm's actions are fixed to the one
policy that created it. On `TreatMissingData` for the queue-depth alarm: I would argue
for `breaching` rather than `notBreaching`, because a missing datapoint on a metric
the *application itself* is responsible for publishing most plausibly means the
application has stopped publishing — which is itself a fault worth treating as bad,
not neutral. The documented risk of choosing `breaching`: if the application is
healthy but briefly stops publishing for an unrelated reason (a deploy, a restart of
the publishing sidecar), the alarm would fire and scale out for a problem that isn't a
capacity problem at all — a false positive this lab's own choice of `notBreaching`
was built specifically to avoid, at the cost of the blind spot just described.

**5. The reactive-scaling arithmetic, and which decision each consequence justifies.**

The arithmetic, term by term: the managed high alarm needs **3 evaluation periods at
60 seconds** (3 minutes) of sustained breach before firing at all; invoking the policy
and calling `UpdateService` is near-instant; a Fargate task takes roughly
**20–60 seconds** to exist (the course's own cited figure); and Lab 05's
`healthCheckGracePeriodSeconds` of **60 seconds** withholds a brand-new task from
counting as real capacity even after it starts. Summed, a reactive policy's realistic
best case before new capacity is actually serving traffic is on the order of
**4.5 to 5 minutes** after a spike begins — all of which is served, if it is served at
all, by whatever capacity already existed. The three consequences and the decisions
each justifies: (a) "minimum capacity is a latency decision, not a cost decision"
justifies this lab's floor of 2 (one task per AZ, Lab 04's decision, carried forward
rather than lowered); (b) "scale-out eager, scale-in reluctant" justifies the
`ScaleOutCooldown`/`ScaleInCooldown` asymmetry (60s vs. 300s) chosen in Step 7; (c)
"a known spike needs scheduled, not reactive, scaling" justifies Step 11's two
scheduled actions existing at all, independent of whether any reactive policy ever
fires.

**6. Two target tracking policies disagreeing, and why same-metric duplication is a fault.**

When two target tracking policies disagree about whether to scale out, the rule is
asymmetric and deliberately so: **scale-out, the largest capacity any policy
requests wins**; **scale-in, only when every policy agrees it's safe.** The asymmetry
is a conservative bias: "should I have more capacity" only needs one "yes," while
"can I have less" needs unanimous agreement, because the cost of being wrong in each
direction is different (a slow response vs. an outage). Two target tracking policies
on the *same* metric with *different* targets is a fault, not redundancy, because each
one is independently trying to drive that one metric to its own target value — they
fight, and the service oscillates between the two set points with neither ever
"winning" stably. A step scaling policy and a target tracking policy on the same
metric is the identical mistake in different clothing: the step policy reacts to
absolute breach magnitude on a schedule of its own (its alarm's period and
evaluation count), the target tracking policy reacts continuously to the same
underlying number, and the two mechanisms' different timing and different math can
each move capacity in response to the same signal without either being aware the
other exists — the same uncoordinated-dual-control problem, just with a different
pair of mechanisms doing the colliding.

**7. Why `ALBRequestCountPerTarget` beats CPU, when CPU wins, and when requests would scale badly.**

The three reasons stated in this lab: (a) CPU is only meaningful relative to an
arbitrary task-size reservation chosen in the task definition, so the *same*
real-world load reports differently depending on a sizing decision that has nothing
to do with load; requests-per-target means the same thing regardless of task size.
(b) CPU lags — a request is queued and processed *before* it consumes CPU, so an
I/O-bound service waiting on a slow database can be fully saturated while still
reporting low CPU; request count moves the instant load does. (c) Requests per
target is a number the business already has a feel for ("we expect 1200 concurrent
registrations"), where a CPU percentage translates into nothing a product owner can
reason about. The one case CPU is the better signal: a **CPU-bound workload with
highly variable cost per request** — a PDF/transcript renderer, where one request
might cost a hundred times another — because there, request *count* is a poor proxy
for load and CPU measures the resource that is actually running out. For
`ALBRequestCountPerTarget` to scale the enrolment service badly, the per-request cost
would have to vary enormously and unpredictably (exactly the CPU-favoring case above)
or the service would have to be bottlenecked on something requests-per-target cannot
see at all, such as a downstream database connection pool exhausting before the task
itself is under any real load. The CloudWatch metric that would have shown this
*before* choosing the policy: `AWS/ECS CPUUtilization` (or the database's own
connection-count metric) staying flat or low while request latency and error rates
climb — evidence that adding tasks in response to request volume would not actually
relieve the real bottleneck.

## Exercise 4 — the enrolment-week capacity plan (the part of this lab Path C most needs)

**Is reactive scaling alone the solution?** No, in exactly three sentences: reactive
scaling will correctly and continuously track *gradual* changes in load across the
three-week window, adding and removing a task or two as the day's baseline traffic
rises and falls. It will do badly against the three cohort-eligibility spikes, because
forty times normal traffic arrives faster than any alarm-evaluation-plus-task-start
cycle can follow, and by the time the policy has reacted the spike's worst few minutes
are already over. For the first twenty minutes specifically, reactive scaling cannot
help at all — the arithmetic in Review Question 5 (on the order of 4.5–5 minutes to
first new capacity, repeated across however many scale-out cycles are needed to climb
from a floor of 2 toward whatever the spike demands) means a human-observed "first
twenty minutes" outage last year was, structurally, baked into relying on reactive
scaling for a known-in-advance event.

**Why 40x traffic is not simply a scaling problem.** From this lab's own numbers: the
fastest possible reactive climb from 2 to 10 tasks is bounded below by at least one
full cycle of (3 min alarm evaluation + ~1 min task start + 1 min grace period) ≈ 5
minutes just to add the *first* batch, and the `ScaleOutCooldown` of 60 seconds means
further scale-outs are gated at best once a minute after that — so climbing from 2 to
10 takes multiple minutes under the most generous assumptions, well past the 20
minutes the spike itself lasts in the worst historical case, but more importantly: the
**ceiling of 10 tasks at a target of 1000 requests/target/minute is a hard cap of
10,000 requests per minute (≈167 req/sec) regardless of how fast scaling reacts.**
Forty times "normal" traffic, if normal is anywhere near what two tasks already
serve, is very plausibly above that ceiling outright — in which case no amount of
scaling speed matters, because the system was never going to have enough room to grow
into.

**The ceiling, checked against Lab 02's subnets.** AWS reserves 5 IP addresses in
every subnet (the network address, the VPC router, the two addresses reserved for the
DNS server and for future use, and the broadcast address) — documented in the Amazon
VPC User Guide's subnet sizing section. A `/24` subnet has 256 addresses total, so
`10.0.3.0/24` and `10.0.4.0/24` each offer `256 - 5 = 251` usable addresses before
anything else is placed in them. Every `awsvpc` Fargate task consumes exactly one
address from whichever subnet it lands in, and `usms-db-01` (Lab 03) already occupies
one address in `usms-private-subnet-a`. With two subnets available to the service and
roughly even placement, the subnets could comfortably support a ceiling far higher
than 10 — the address count is not the binding constraint here, the chosen
`MaxCapacity` of 10 is a deliberate guard rail, not a subnet-imposed limit, and could
safely be raised for the enrolment window without running into IP exhaustion.

**A concrete plan.** Three scheduled actions for the cohort days (adjust the actual
dates to the real calendar): `cron(0 7 14,21,28 11 ? 2026)` (7:00 Asia/Thimphu on each
cohort day, in `at()` form per exact date if `cron`'s day-of-month/month-list syntax
is awkward) raising `MinCapacity` to 8 and `MaxCapacity` to 20 for a 3-hour window
around each cohort's eligibility opening, then a scheduled action reverting to the
window-wide floor. For the three-week window overall: `MinCapacity` 4 / `MaxCapacity`
15 for the full three weeks (double-normal baseline), with the existing
`usms-enrolment-requests-target-tracking` target lowered from 1000 to roughly 600–700
requests/target/minute during the window, so the policy reacts earlier and holds more
headroom per task than the steady-state target does. All of these are scheduled
actions and are reversible in one `put-scheduled-action` call each; raising
`MaxCapacity` to 20 is the one change that is not "free" to leave in place afterward,
since the guard rail is specifically there to cap a runaway policy or an errant metric.

**Monthly cost estimate.** Baseline (this lab, 2 tasks, 256 CPU / 512 MiB, running
continuously): at current Fargate Linux/x86 pricing for `us-east-1` (approximately
$0.04048 per vCPU-hour and $0.004445 per GB-hour — AWS Fargate pricing page, checked
at time of writing and worth re-verifying against the live page before quoting to
finance), 2 tasks × 0.25 vCPU × $0.04048 × 730 hours ≈ $14.78/month for CPU, plus 2 ×
0.5 GiB × $0.004445 × 730 ≈ $3.25/month for memory — roughly **$18/month** baseline.
The proposed 3-week window at a floor of 4 (double the baseline task-count for
roughly half the month) adds approximately half a month's worth of 2 extra tasks:
≈$9/month pro-rated to 3 weeks ≈ **$7** additional. The three cohort-day spikes to a
floor of 8 for 3 hours each add a negligible few cents. CloudWatch: this lab's alarms
and one custom metric are on the order of a few dollars a month (each standard alarm
is approximately $0.10/month, and a custom metric similarly small) — call it **$2–3
extra** for the additional scheduled-action-driven state, though scheduled actions
themselves create no new alarms. **Total estimated incremental cost: roughly
$10/month** for the three-week enrolment period, against a baseline of $18/month —
all figures provisional and explicitly dependent on verifying current list prices
before presenting them as a real budget number.

**What I need from the project lead.** (1) A real load test of the enrolment API
under realistic single-task load, so that the 1000-requests-per-target target value
in Step 9 — currently "provisional," per §12.4 — can be replaced with a measured
number; this is the measurement nobody has taken yet. (2) The exact cohort-eligibility
times for this specific semester, since the scheduled actions above use placeholder
dates. (3) Confirmation of whether "forty times normal" is defined against the whole
service's traffic or against a single task's capacity — the two give very different
ceiling requirements, and the project lead's own phrasing conflates them.

**Tidy-up.** Nothing from this lab's own build needs tidying (no Exercise 1/2 practice
policies exist, since Application Auto Scaling itself was unavailable to create them
on). The one object genuinely created — the `usms-enrolment-queue-high` alarm — is
listed in Section 16's KEEP column and is left in place.
