# Lab 07 notes

## Support path

**Path A.** `aws eks list-clusters` returned a genuine, successful empty list
(`{"clusters": []}`) before anything existed — not an error, not
`UnknownOperationException` — and every subsequent `aws eks` call behaved the same
way: real objects, real state transitions, real errors on real mistakes. `kubectl`
was already installed (`v1.36.3`); `k3d` was not needed. Confirmed further by
`docker ps` showing a genuine `rancher/k3s:latest` container running for the cluster,
and real per-pod containers for every Deployment — this build does not merely model
the EKS API, it runs an actual, small, real Kubernetes distribution underneath it.

## Step 3 "Your turn" — is "EKS is just ECS with different names" true?

False in one specific, load-bearing way: ECS with Fargate (Practical 2) gives you
no data plane at all — there are no machines to patch, size, or lose sleep over, and
`usms-ecs-cluster` genuinely held nothing but a namespace. EKS's managed node group
in this lab is real machines in your account that you chose an instance type for,
and that choice caps how many pods can run — a decision category Fargate removed
entirely. Nearly true in a different way: both platforms reduce to the identical
abstract loop — a declared desired state, a controller that reconciles reality
toward it, and a stable name in front of a changing set of backends. `desiredCount`
and `replicas` are the same idea with a different noun attached.

## Review questions

**1. `ACTIVE` cluster, every pod `Pending` — how can both be true?**

The control plane (`kube-apiserver`, `etcd`, the scheduler) is a service AWS runs
and reports on independently of whatever is or isn't attached to it as a data
plane; `ACTIVE` is a true statement about *that* half alone. A pod stuck `Pending`
is the scheduler correctly reporting that it has nowhere to place it — the control
plane is doing its job by refusing to schedule onto nothing. Two configurations
that produce exactly this: (a) an EKS cluster created with no node group at all —
Step 3's own stated reason for existing — and (b) a node group whose instance type
or count genuinely cannot satisfy a pod's resource requests, which this lab
reproduced on purpose in Step 19's Failure 2 (`FailedScheduling: Insufficient cpu,
Insufficient memory`).

**2. Swapping the cluster role's and node role's trust policies — what breaks, and when would you notice on real AWS?**

If the cluster role trusted `ec2.amazonaws.com` instead of `eks.amazonaws.com`, the
EKS control plane itself could never assume it, because nothing but the EKS service
principal is permitted to — `create-cluster` would fail immediately, before any
subnet or node group is even considered, with an error about the role's trust
policy. If the node role trusted `eks.amazonaws.com` instead of `ec2.amazonaws.com`,
cluster creation would succeed (the cluster role is independent), but every EC2
instance EKS tries to launch into the node group would be unable to assume its own
instance role — on real AWS this surfaces at node-group creation or shortly after,
with nodes that never register and never reach `Ready`, and the failure is
specifically at Step 10/11, not Step 6. The asymmetry matters: one swap fails loud
and immediately (Step 8); the other fails later and more confusingly (Step 10–11),
which is exactly why the guide calls a node role trusting `eks.amazonaws.com` "the
single most common error in this lab."

**3. Readiness vs. liveness probe — the distinction, and a concrete failure from getting it backwards.**

A readiness probe controls whether a pod is a member of its Service's endpoint
list; failing it removes the pod from load-balancing *without* restarting it. A
liveness probe controls whether the kubelet restarts the container at all; failing
it kills and recreates it. The concrete failure from wiring them backwards: imagine
a pod temporarily busy under load (a legitimate, recoverable readiness failure)
wired to a liveness check instead. The kubelet, seeing what it believes is a
liveness failure, kills the container — removing capacity at the exact moment more
capacity was needed, which pushes the remaining pods further into the same
overload, which fails their liveness checks too. Wired correctly, the busy pod
simply drops out of the Service's endpoint list, finishes its work, and rejoins —
no restart, no cascading failure.

**4. Rollback left `usms-enrolment` still reporting version `1.1.0` — why, and is Kubernetes rollback "not really a rollback"?**

Observed directly in this build: `kubectl rollout undo` reverts the Deployment's
own pod *template* to a previous ReplicaSet — image, env vars, probes, resource
requests — but a ConfigMap is a separate object the Deployment merely references by
name; rolling back the Deployment does not roll back objects it does not own. The
running pod still reads `APP_VERSION` from the *current* ConfigMap, which was never
part of the rollback at all. I would argue this is not evidence that Kubernetes
rollback is broken, but that "rollback" was never well-defined for a release that
spans more than one object — the Deployment's own revision history does exactly
what it promises (revert *this* object), and the gap is a release-process gap, not
a tooling gap. The practice that resolves it: version configuration *with* the
workload — either as an immutable, versioned artefact referenced by a label
(the way the application's own image tag is versioned) or via a GitOps tool that
rolls back every object in a release atomically, rather than treating the
Deployment as the sole unit of release.

**5. `maxUnavailable: 0` vs. the default `25%` — what each does, and which is closer to Lab 04's ECS configuration?**

With `maxUnavailable: 0` (`usms-enrolment`), an update must add at least one new,
ready pod before removing any old one — capacity never drops below the current
replica count during the rollout, at the cost of needing headroom for the
extra pod. With the default (`maxUnavailable: 25%`, `maxSurge: 25%`, `usms-results`),
on two replicas that rounds to permitting one pod unavailable at a time — faster,
cheaper in headroom, but capacity genuinely dips during the update. The first suits
a service where every request matters and a brief capacity dip is unacceptable
(exactly why it was chosen for the student-facing enrolment path); the second
suits a service that can tolerate a short dip for a faster, cheaper rollout (the
results endpoint, explicitly described as low-stakes in Step 14). Lab 04's ECS
service used `minimumHealthyPercent: 100` / `maximumPercent: 200` — never drop
below current capacity, allow up to double during the roll — which is the same
*policy* as `maxUnavailable: 0`, expressed as percentages of total capacity instead
of a count. `usms-enrolment`'s configuration is the closer match.

**6. "It's encrypted, so it's fine to commit the manifest" — correcting the claim.**

A Kubernetes Secret stores its values base64-*encoded*, not encrypted — demonstrated
directly in Step 17: `kubectl get secret ... -o jsonpath='{.data.ENROLMENT_API_TOKEN}'
| base64 -d` reverses it with no key and no special permission beyond read access to
the Secret object. What a Secret genuinely provides: the value is kept out of the
container image, it is a separately RBAC-restricted object type from a ConfigMap,
and `kubectl describe` does not print its contents by default. What it does *not*
provide, without additional configuration: confidentiality at rest in etcd (plain
base64 unless the cluster operator has configured KMS envelope encryption) or any
protection once the data reaches the running container, where `printenv` shows it
in plain text — because inside the container it always was plain text. On real
EKS, the better answer for an AWS credential specifically is not a more careful
Secret at all, but IRSA (Step 21): the pod never holds a stored credential in the
first place, so there is nothing in etcd or in a committed manifest to leak.

**7. ECS (Lab 04) vs. Kubernetes (this lab) for USMS specifically — a small team, one region, eight quiet months and two busy ones.**

For USMS as described, I would argue for ECS with Fargate. Two things this lab was
genuinely harder than Lab 04: this lab required two IAM roles with a subtle,
easy-to-invert trust-policy distinction (Review Question 2) where Lab 04 needed
only the execution/task role pair with an identical trust policy for both; and this
lab required choosing and sizing real node group capacity (Step 10) — a decision
Fargate removes entirely, and one a small team maintaining a system busy two months
a year has no appetite to keep tuned. One thing Kubernetes genuinely gave that ECS
could not, observed directly in this lab: in-cluster service discovery by DNS name
with zero additional AWS objects — `usms-gateway` holds two hostnames and nothing
else, where Lab 05 needed an entire Application Load Balancer, target group and
listener stack to achieve the ECS equivalent. For a workload at USMS's described
scale, though, that one genuine advantage does not outweigh the ongoing node-group
and two-role operational burden a small team would carry for eight quiet months a
year — the case for Kubernetes strengthens sharply with team size and multi-service
count, neither of which USMS has yet.
