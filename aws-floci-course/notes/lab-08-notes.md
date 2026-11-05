# Lab 08 notes

## Support path

**Path A**, same as Lab 07. The cluster, namespace and all three microservices
were already running from Lab 07. Every object built in this lab — the HPA, the
load generator, both PDBs, the NodePort Service, the LoadBalancer Service and
the Ingress — was created against the live k3s cluster and verified from real
`kubectl` output, not asserted.

## A mid-lab environment incident, and what it proved

Partway through this lab the host's Docker Desktop had to be restarted. On
restart, the EKS emulation container (`floci-floci-course-eks-usms-eks-cluster`)
came back up but its embedded k3s process crashed immediately and repeatedly
with:

```
level=fatal msg="Failed to start networking: unable to initialize network policy
controller: error getting node subnet: failed to find interface with specified
node ip"
```

Diagnosis: k3s's own persisted state (bind-mounted, `FLOCI_STORAGE_MODE=hybrid`)
recorded the node's registered address as `172.17.0.3` — the IP the container
held during Lab 07/08's earlier work on Docker's default `bridge` network.
After the Docker Desktop restart, nothing else had claimed the default bridge
network's address pool, so the container was reassigned `172.17.0.2` — the next
free address — on reconnect. Flannel's startup check reads the IP already
recorded against the Node object and fails fatally if no local interface
carries that exact address; it does not fall back to whatever address the
container actually has.

The default `bridge` network refuses a user-specified static IP
(`"user-specified IP address is supported on user-defined networks only"`), so
the address could not be pinned directly. The fix: start a disposable
placeholder container on the same bridge network first, with no explicit IP,
to claim `172.17.0.2` ahead of the real one — Docker's sequential allocator
then gave the EKS container `172.17.0.3` on the next connect, exactly matching
what k3s's persisted state expected. k3s started cleanly on the next attempt
and the placeholder was removed immediately afterward.

This is not a course-scripted exercise, but it is a legitimate, stronger
version of Step 18's own persistence proof: every Lab 08 object — the HPA's
bounds, both PDBs, the pinned NodePort, the LoadBalancer's allocated nodePort,
and the Ingress's three paths — survived a full, unplanned container crash and
manual recovery with no data loss, not just the course's own `floci-down.sh` /
`floci-up.sh` cycle (which was also run afterward, as Step 18 prescribes, and
also produced a byte-identical diff). It is also a direct, concrete instance of
Step 3's "four dimensions of scaling" framing from a different angle: the
*infrastructure* holding the cluster's identity (a container's network address)
is itself a kind of state that can drift from what a stateful system expects,
independent of anything the course's own manifests describe.

## Corrections to the source material

- The HPA, load generator and Ingress manifests in the published guide all
  carried `lab: "05b"` as a label — evidently a leftover draft numbering from
  before this practical was renumbered to Lab 08, the same kind of copy-paste
  artifact caught in Lab 07's namespace manifest (`lab: "05a"`). Corrected to
  `lab: "08"` in all three manifests actually applied, consistent with the
  established practice of fixing clearly-wrong transcription artifacts rather
  than reproducing them.

## Step 7 — a specific, reproducible false negative in the guide's own check

The guide's own diagnostic command,
`kubectl get --raw /apis/metrics.k8s.io/v1beta1`, returned
`Error from server (NotFound): the server could not find the requested resource`
on this build, which looks exactly like "metrics API: NOT AVAILABLE." But
`kubectl top nodes` and `kubectl top pods` both succeeded immediately, with
real, distinct per-pod figures, and the HPA created in Step 8 read a working
percentage from the first poll. The raw discovery path for the bare API group
(with no resource kind appended) does not resolve on this k3s build, even
though the underlying metrics pipeline is fully functional — `kubectl top` is,
exactly as the guide says elsewhere, "the single diagnostic for 'is my HPA
going to work?'", and it is a better one than the guide's own suggested raw
path. Idle baseline recorded: ~1m CPU per pod against a 50m request, i.e. ~2%
— comfortably under the 50% target, as the guide anticipates.

## Step 10 — a new Floci gap: `update-nodegroup-config` is misrouted

`aws eks update-nodegroup-config --scaling-config minSize=2,maxSize=6,desiredSize=3`
did not return an EKS-shaped error. It returned:

```
An error occurred (400) when calling the UpdateNodegroupConfig operation:
<?xml version="1.0" encoding="UTF-8"?><Error><Code>InvalidArgument</Code>
<Message>POST requires either ?uploads, ?uploadId, ?restore or ?select
parameter.</Message>...</Error>
```

That is an S3 multipart-upload error, not an EKS error — the call appears to
be misrouted on this build to S3's request-validation code path rather than
to EKS's. Retried once, with an identical result, and `describe-nodegroup`
confirmed the scaling configuration was genuinely unchanged
(`minSize=2,maxSize=4,desiredSize=2`) both times. This is a different category
from every previous Floci gap recorded in this course: not
`UnknownOperationException` (the operation is unrecognised entirely, as with
Application Auto Scaling in Lab 06), not `UnsupportedOperation` (a named,
known-but-unimplemented IAM call, also from Lab 06), and not a silent
accept-then-drop (Lab 05's health-check grace period, Lab 06's
`treat-missing-data`). Here the operation name is recognised well enough to be
accepted, but the request appears to be dispatched to the wrong emulated
service's handler entirely. `configs/lab-08.env`'s three `USMS_NODEGROUP_*`
values and `verify-lab-08.sh`'s one documented `FAIL` both record this
precisely rather than working around it.

## Step 11 — node group labels did not reach the nodes, as the guide anticipates

`kubectl get nodes --show-labels` showed neither `workload=usms` nor
`tier=app` before they were applied by hand — the same propagation gap the
guide names explicitly. Applied by hand, then proved enforced: patching
`usms-enrolment`'s `nodeSelector` to `workload: nonexistent` left the two
running pods serving traffic (protected by `maxUnavailable: 0`) while the one
new pod sat `Pending` with
`FailedScheduling: 0/1 nodes are available: 1 node(s) didn't match Pod's node
affinity/selector`. Reverted, and the repository's
`manifests/lab-07/20-enrolment.yaml` was updated with the `nodeSelector` block
so `kubectl diff` now reports no difference — Step 5's drift-prevention habit,
applied again.

## Step 12 — PDBs, and an MSYS path bug caught a second time in this course

The raw eviction call,
`kubectl create --raw "/api/v1/namespaces/usms/pods/$POD/eviction" -f ...`,
initially failed with a plain `404 Not Found`. Verbose output
(`-v=6`) showed why: Git Bash had rewritten the leading `/api/v1/...` into
`/Program Files/Git/api/v1/...` — the same MSYS path-mangling bug first caught
on `--health-check-path /` in Lab 05, recurring here on a raw API path rather
than a CLI flag. Fixed with `MSYS_NO_PATHCONV=1`, after which the eviction
correctly returned
`Error from server (TooManyRequests): Cannot evict pod as it would violate the
pod's disruption budget`. A plain `kubectl delete pod` on the same pod
succeeded immediately afterward, with no PDB involvement at all — both
outcomes are correct, and the contrast is the entire point of the step.

This cluster has exactly one node, so the drain dry-run
(`kubectl drain ... --dry-run=client`) would evacuate *every* workload pod in
the namespace plus `kube-system`'s own pods, not "roughly half" as the guide's
two-node assumption describes — a stronger, not weaker, illustration of why
`usms-gateway-pdb`'s `ALLOWED DISRUPTIONS: 0` matters on a single-replica
service with nowhere else to go.

## Steps 13-14 — two host-port collisions, investigated rather than assumed

`http://localhost:30080/` answered on the first attempt — but with a generic
nginx welcome page, not this lab's JSON. `docker ps --filter publish=30080`
showed the real owner: `dso202-control-plane`, an unrelated course's `kind`
cluster bound to `127.0.0.1:30080` on this same machine. `docker port` on the
actual EKS container confirmed it publishes only `6443->6500` and nothing
else — the NodePort genuinely is not reachable from the host, exactly as the
guide's Floci Limitation predicts, and the first result was a coincidental
false positive from a different container entirely, not evidence against the
limitation. A second attempt at the documented port-forward fallback
collided again, this time with an unrelated local dev server on `30081`;
resolved by picking a confirmed-free local port (`netstat -ano` showed
`41234` unused) before retrying. The fallback then worked as documented,
proving the Service routes correctly without claiming host reachability it
does not have.

## Step 15 — LoadBalancer got a real address

`usms-gateway` received `EXTERNAL-IP 172.17.0.3` within the expected window —
the bridge-network address of the k3s container itself, published by this
build's internal load-balancer emulation. `curl` against it from the host
succeeded. The nodePort (`30799`) and clusterIP were both still present
alongside it — the superset property the guide describes, observed directly.

## Step 16 — no Ingress controller, and a specific, confirmed reason why

`kubectl get ingressclass` returned nothing, and no Traefik or nginx
controller pod existed anywhere in the cluster. The reason is not a vague
"this build may not include one": `docker inspect` on the EKS container's own
`Config.Cmd` showed `k3s server --disable=traefik ...` — the flag that
suppresses k3s's normally-bundled Traefik ingress controller is explicitly set
on this build. The Ingress object itself was created, stored, and served by
the API server with its three prefix paths all correctly resolved against
live Service endpoints (visible in `kubectl describe ingress`'s `Backends`
column) — it simply has nothing acting on it, which is a true and complete
description of the object's state, not a partial one.

**Which four `aws elbv2` commands would the AWS Load Balancer Controller have
run, and in what order?** Reading the three annotations against Lab 05's own
command sequence: (1) `aws elbv2 create-load-balancer` with
`--scheme internet-facing`, placed in the public subnet pair, matching
`alb.ingress.kubernetes.io/scheme: internet-facing`; (2) one
`aws elbv2 create-target-group --target-type ip` per backend Service named in
the Ingress's rules (three here: gateway, enrolment, results), matching
`alb.ingress.kubernetes.io/target-type: ip`; (3)
`aws elbv2 create-listener --port 80`, matching
`alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'`; (4) one
`aws elbv2 create-rule` per path, in priority order, with the `/` rule given
the lowest priority (evaluated last) since the other two are more specific —
the Kubernetes side expresses this as longest-prefix-match instead of an
explicit numeric priority, but the controller would still have to pick
concrete priorities when translating it to `elbv2`'s model.

## Step 17 - Practical 2 and Practical 4, compared with both running

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | `desiredCount` on the ECS service | `spec.replicas` on the Deployment |
| Who writes it? | Application Auto Scaling, via `RegisterScalableTarget` + a `TargetTrackingScaling` policy — confirmed absent on this build (`UnknownOperationException` on `DescribeScalableTargets`, same as Lab 06) | The HPA controller, part of the Kubernetes controller manager — confirmed present and active, `cpu: 2%/50%` read live |
| Where does that thing run? | Inside AWS, outside anything the student's account directly operates | Inside the cluster's own control plane — on EKS, inside the AWS-managed control plane; functionally similar to the ECS case, but the HPA *object* itself lives in the cluster's own API, not a separate AWS service |
| Where does the metric come from? | CloudWatch (`ECSServiceAverageCPUUtilization`, or a custom metric as in Lab 06 Exercise 4) | the metrics pipeline (`kubelet` -> `metrics-server` -> `metrics.k8s.io`), observed working on this build despite the guide's own raw-API check reporting a false negative |
| What does "50% CPU" mean - 50% of what? | 50% of the ECS task's reserved CPU (the task definition's `cpu` field) | 50% of the container's declared `resources.requests.cpu` (50m here) — analogous, not identical: one denominator is a task-level reservation, the other a container-level one |
| How is scale-in slowed down? | `ScaleInCooldown` (seconds) on the scaling policy — designed but never submitted to a live API on this build (Path C) | `behavior.scaleDown.stabilizationWindowSeconds: 300` — observed directly: CPU fell within seconds of removing load, but `REPLICAS` held at 3 for the full five minutes before dropping to 2, with the event reading `New size: 2; reason: All metrics below target` |
| What happens if there is no capacity for the new instance/pod? | Nothing — Fargate supplies capacity, so this question does not apply to Lab 04's service | The pod stays `Pending` with `FailedScheduling: Insufficient cpu` (reproduced in Lab 07 Step 19); fixing it requires either lowering `maxReplicas` or raising node capacity — which Step 10 showed is itself broken on this build |
| What creates the alarms, if anything? | Two CloudWatch alarms, created automatically by the target-tracking policy (Lab 06's `templates/lab-06-target-tracking-cpu.json` documents their shape, though none were ever live) | None. The HPA controller polls the metrics API directly on a fixed interval; there is no alarm object anywhere in this picture |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | Four, by hand, one `aws elbv2` call each: load balancer, target group, listener, rule | Zero directly — one Ingress manifest, applied once, encodes all four |
| What is the target type, and why? | `ip` — a Fargate task has its own ENI/VPC address, so the ALB reaches it directly without a node hop | `ip`, via the `alb.ingress.kubernetes.io/target-type: ip` annotation — same reasoning, same value, carried over verbatim |
| How are targets registered and deregistered? | `register-targets`/`deregister-targets`, called implicitly by the ECS service's own lifecycle on task start/stop, with a 30-second deregistration delay this lab configured by hand | The AWS Load Balancer Controller watches the Service's Endpoints/EndpointSlice objects and registers/deregisters pod IPs automatically — no manual call of any kind on either platform once the controller exists |
| How are competing routing rules disambiguated? | Numeric `--priority` on each `create-rule` call; Lab 05 gave its health-check rule priority 10 so it would be evaluated before the default | Longest-matching-prefix, computed by the ingress controller from `pathType: Prefix`; no explicit priority field exists in the Kubernetes object at all |
| What would I change to move this to another cloud? | Nothing in the application; every `aws elbv2` call and every ARN is AWS-specific infrastructure with no portable equivalent | Nothing in `spec.rules` — only the three `alb.ingress.kubernetes.io/*` annotations are AWS-specific; a different ingress controller (nginx, Traefik) reads the same `spec` and ignores those annotations entirely |
| What is the cost of exposing ten services? | Ten ALBs (or ten listener/rule sets behind fewer ALBs, if hand-managed carefully) — Lab 05's entire manual stack, times ten, unless deliberately consolidated | One Ingress, ten paths, one ALB — this is the entire economic argument Step 16 makes, and it held up concretely: this lab's own Ingress already carries three paths on what would be a single ALB on real AWS |

### Two paragraphs, in prose

**1. If the AWS control plane has a bad afternoon, what happens to each of the
two scaling arrangements, and which of them can I still debug?** Application
Auto Scaling would stop reading CloudWatch metrics and stop writing
`desiredCount`, but the ECS service itself keeps running at whatever count it
last held — the scaling *decision-maker* is external and fails independently
of the workload. The HPA is different in a way this course's own EKS setup
makes concrete: it runs inside the cluster's control plane, which on EKS *is*
an AWS-managed service, so "AWS has a bad afternoon" is closer to the same
failure for both — except that a self-managed Kubernetes control plane (not
what this course built, but a real alternative) would keep the HPA running
during an AWS outage that had nothing to do with it, a resilience option ECS's
Application Auto Scaling structurally cannot offer no matter how it is
deployed. What I can still debug during either outage: on the Kubernetes side,
`kubectl describe hpa` continues to work against whatever control plane is
still reachable and states its own `Conditions` in plain language
(`FailedGetResourceMetric`, `ScalingActive: False`, etc., observed directly in
this lab); on the ECS side, the equivalent is reading CloudWatch alarm history
and `describe-scaling-policies`, assuming CloudWatch itself is part of what
failed.

**2. For USMS specifically - one small team, one region, quiet for eight
months and very busy for two - which would I choose, and what is the
strongest argument AGAINST my own choice?** I would choose ECS with Fargate
and Application Auto Scaling, for the same reason Lab 07's Review Question 7
gave: Fargate removes node-capacity decisions entirely, and this lab's own
Step 10 finding (`update-nodegroup-config` misrouted and silently ineffective
on this build) is a sharp, concrete illustration of exactly the kind of
infrastructure-layer fragility a small team maintaining a system for two busy
months a year has no appetite to debug — even though that specific failure is
an emulator artefact and not a real-AWS behaviour, the *category* of problem
(node-group capacity management being a separate, fallible control loop from
pod scaling) is real on EKS regardless of this build's bugs. The strongest
argument against my own choice: this lab's Ingress, in seven lines of YAML,
expressed routing for three services that took four separate hand-typed
`aws elbv2` commands in Lab 05 and would need three more sets of those same
four commands to add two more services — if USMS's "quiet eight months"
include building out additional microservices rather than just running the
existing three, the Kubernetes side's near-zero marginal cost per added
service (one more path, no new infrastructure) is a real, compounding
advantage that ECS's per-service ALB model does not have, and that advantage
grows faster than the operational burden my own choice is trying to avoid.

## Review questions

The published extraction of this lab's Section 15 did not survive the
PDF-to-text conversion (confirmed: the source transcription's own note states
the file ends mid-sentence inside Section 14's checklist, before Section 15
begins). The four review-question topics the guide refers to by number
in-text — the two-loop picture (Step 10/11), the gateway-bypass architectural
choice (Step 16), and the two comparisons assumed by Step 17 (Questions 3 and
7, both answered above as the prescribed Step 17 table and prose) — are
answered here from their referenced context rather than invented wholesale.

**On the two-loop picture (referenced at Step 10/11):** Step 9 and Step 10
write to two different APIs that nothing connects automatically on this build:
the HPA writes `spec.replicas` the moment it sees `cpu > 50%`, no human
involved; `update-nodegroup-config` would, on real AWS, drive an Auto Scaling
group's desired capacity that a Cluster Autoscaler watches and responds to by
launching EC2 instances — but no Cluster Autoscaler is installed here (it
needs IRSA, confirmed unavailable since Lab 07 Step 21), and on this specific
build the AWS-side call itself does not even work (Step 10's misrouting
finding). The two loops are independent by design on real EKS too: Step 9's
pod-count loop reacts in seconds; Step 10/11's node-count loop, even working
correctly, reacts in minutes, because launching and bootstrapping an EC2
instance is categorically slower than starting a container on an
already-running node. Nothing in this course's build demonstrates the
automatic connection between them (that is exactly what Cluster Autoscaler or
Karpenter would be for), which is itself the lesson: scaling pods and scaling
nodes are two loops, not one, unless something is explicitly installed to
join them.

**On the gateway-bypass choice (Step 16):** the Ingress's `/enrolment` rule
reaches `usms-enrolment` directly, bypassing `usms-gateway` entirely, even
though the gateway already proxies the same path. I would keep both paths
deliberately asymmetric rather than remove one: the gateway's own purpose
(observed since Lab 07) is to add a uniform JSON envelope and strip a path
prefix for *internal, service-to-service or developer* consumption, while an
edge Ingress exists to make a routing decision *before* traffic enters the
cluster's own application logic at all — collapsing them into one path means
every external route must also pass through whatever the gateway does,
whether or not that is wanted for that caller. The argument against this
position: two paths to the same backend is also exactly the kind of drift
Step 5 warned about, expressed architecturally instead of as a YAML field — if
the gateway's behaviour changes (say, it starts adding an auth header) and the
Ingress route is forgotten, external callers silently get a different contract
than internal ones, with nothing to catch it.

## Exercises 1-5

Not attempted in this session. `labs/lab-08-eks-scaling/exercises.md` was not
created; the five independent exercises (a second HPA for `usms-results`,
making the gateway drainable, the two-fault broken-HPA diagnosis, the
"expose results without a second load balancer" design brief, and the
integration artefacts for a later lab) remain available as a follow-up if the
course requires them submitted separately from the core lab steps recorded
here.
