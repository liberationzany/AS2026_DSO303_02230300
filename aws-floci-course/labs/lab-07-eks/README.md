# AWS Practical Laboratory Report — Lab 07: Microservices on Amazon EKS

## 1. Aim / Objective

To rebuild the USMS workload on Amazon EKS — a cluster, a managed node group, and
three interdependent microservices (`usms-gateway`, `usms-enrolment`, `usms-results`)
discovering each other by DNS rather than by address — using the AWS CLI and
`kubectl` against Floci, and to compare the Kubernetes object model directly against
the ECS model Practical 2 built.

## 2. Introduction

EKS splits responsibility down the middle: AWS operates the **control plane**
(`kube-apiserver`, `etcd`, the scheduler) and the account owner operates the **data
plane** (EC2 nodes, the kubelet, the pods). This is the opposite trade from Lab 04's
Fargate cluster, which held no machines at all. Five Kubernetes nouns matter: a
**Pod** (cattle — one or more containers scheduled together), a **ReplicaSet**
(keeps N identical pods alive), a **Deployment** (owns ReplicaSets, rolls from one
to the next — the object you actually write), a **Service** (a stable DNS name and
virtual IP in front of a changing pod set), and a **Node** (the machine a pod runs
on). The entire lab is the "write `spec`, a controller makes it true, it writes
`status`" loop, applied five times.

**Key features used in this practical:**
- Two distinct IAM roles with different trust principals (`eks.amazonaws.com` for
  the control plane, `ec2.amazonaws.com` for the nodes) — the single most
  commonly-inverted pair in the lab
- `--cli-input-json` for `create-cluster`/`create-nodegroup`, for the same reason
  Lab 03 used it: a committed, reviewable request body instead of ambiguous shorthand
- Declarative manifests (ConfigMap, Deployment, Service, Secret) applied with
  `kubectl apply`, and cluster DNS resolving a Service name to a live pod set with
  no load balancer involved at all
- A rolling update and a rollback, including the specific gap between what a
  Deployment rollback reverts and what it does not
- Three deliberately broken pods, diagnosed with `kubectl describe` and the event
  stream rather than guessed at

## 3. Use Case

| Service | Role | Replicas |
|---|---|---|
| `usms-gateway` | nginx reverse proxy; the only front door; proxies `/enrolment/` and `/results/` by DNS name | 1 |
| `usms-enrolment` | returns JSON including its own pod identity | 2 |
| `usms-results` | returns JSON including its own pod identity | 2 |

`usms-gateway` never learns a pod address. Its configuration contains exactly two
hostnames (`usms-enrolment.usms.svc.cluster.local`,
`usms-results.usms.svc.cluster.local`) and the cluster keeps them pointing at
healthy pods — the reason this lab has three services instead of one.

## 4. System Architecture / Design

```
YOUR MACHINE
  aws CLI --------> Floci (port 4566)
                          | creates and manages
  kubectl --------> EKS control plane container (real k3s, confirmed via `docker ps`)
      https://localhost:6500
                          | schedules pods onto
                    usms-eks-nodes (managed node group)

INSIDE THE CLUSTER — namespace "usms"
  Service usms-gateway (ClusterIP) --> Deployment usms-gateway (1 pod, nginx)
       /enrolment/ -> usms-enrolment.usms.svc.cluster.local:80
       /results/   -> usms-results.usms.svc.cluster.local:80
            |                                    |
            v                                    v
  Service usms-enrolment (ClusterIP)   Service usms-results (ClusterIP)
    --> Deployment, 2 pods                --> Deployment, 2 pods

  ConfigMaps: usms-app-config (shared), usms-enrolment-conf, usms-results-conf,
              usms-gateway-conf (one nginx template each)
  Secret: usms-enrolment-secret (base64, demonstrated NOT encrypted)

AWS-SIDE OBJECTS, IN LAB 02'S VPC
  usms-eks-cluster-role  trusts eks.amazonaws.com -> USMSEKSClusterPolicy
  usms-eks-node-role     trusts ec2.amazonaws.com -> USMSEKSNodePolicy,
                                                       USMSStudentDataReadWrite (Lab 01, unchanged, 3rd holder)
  usms-eks-cluster-sg    tcp/443 from 10.0.0.0/16, in usms-vpc
  usms-eks-cluster       ACTIVE, all 4 Lab 02 subnets, tag _lb_ports_=8081,8082
  usms-eks-nodes         ACTIVE, private subnets only, min 2 / max 4 / desired 2
```

## 5. Implementation Procedure

All work was performed against **Floci** (Account ID `000000000000`).

0. **Support path probe:** `aws eks list-clusters` returned a genuine, successful
   empty list — not an error — placing this build on **Path A**. Confirmed further
   by `docker ps` showing a real `rancher/k3s:latest` container for the control
   plane once the cluster was created.
1. **IAM (Steps 4–7):** wrote the two trust policies (quoted heredocs — no
   variables) and the two permissions policies, created `usms-eks-cluster-role`
   (→ `USMSEKSClusterPolicy`) and `usms-eks-node-role` (→ `USMSEKSNodePolicy` +
   Lab 01's `USMSStudentDataReadWrite`, confirmed as that policy's **third**
   holder alongside `usms-ec2-app-role` and `usms-ecs-task-role`).
2. **Cluster security group (Step 6):** created in Lab 02's VPC, tcp/443 from the
   VPC CIDR only — an administrative endpoint, not a public one.
3. **Cluster creation (Step 8):** built `templates/lab-07-create-cluster.json` with
   an **unquoted** heredoc (the opposite choice from the policy documents, and
   deliberately so), assumed `usms-developer-role`, and created `usms-eks-cluster`
   across all four Lab 02 subnets with the Floci-specific `_lb_ports_` tag. Reached
   `ACTIVE` immediately.
4. **Node group (Step 10):** created `usms-eks-nodes` in the two private subnets
   only, min 2 / max 4 / desired 2. `ACTIVE` immediately; `kubectl get nodes` showed
   one real, schedulable control-plane node (no separate agent nodes materialized,
   which is the exact scenario the guide anticipates and does not treat as a fault).
5. **kubectl (Step 11):** `aws eks update-kubeconfig` wrote a working context on
   the first attempt; `kubectl cluster-info` and `kubectl get nodes` both succeeded
   against the real API server.
6. **Namespace and the three microservices (Steps 12–15):** applied in order —
   namespace, shared ConfigMap, `usms-enrolment` (ConfigMap + Deployment + Service,
   `maxUnavailable: 0`), `usms-results` (default rolling-update strategy,
   deliberately different), `usms-gateway` (the reverse proxy). Every rollout
   completed and every DNS-based proxy chain was proven end-to-end with a throwaway
   `busybox` pod — see Evidence 2.
7. **Secret (Step 17):** created `usms-enrolment-secret` from literals,
   demonstrated base64 is not encryption by decoding it with no special
   permission, then consumed it in the enrolment Deployment via
   `kubectl set env --from=secret/...`. Written to `outputs/` (git-ignored) rather
   than committed, per the guide's own better alternative.
8. **Rollout and rollback (Step 18):** changed the shared ConfigMap, proved the
   change did *not* reach running pods, forced a rollout with
   `kubectl rollout restart`, confirmed the new value arrived, then rolled back —
   and confirmed the exact, specific gap the guide predicts: the rolled-back pod
   still reported the *new* ConfigMap value, because `rollout undo` reverts the
   Deployment's pod template, not objects it merely references.
9. **Deliberate failures (Step 19):** reproduced `ImagePullBackOff` (bad tag) and
   `Pending`/`FailedScheduling` (an impossible resource request) for real, read the
   exact `Events` text in both cases, and fixed each.
10. **IRSA (Step 21):** confirmed `cluster.identity.oidc.issuer` is `None` on this
    build — IRSA is Conceptual/Real-AWS here, exactly as anticipated — and created
    the `usms-enrolment-sa` ServiceAccount anyway, since it costs nothing and is
    worth having regardless.
11. **Persistence (Step 22):** recorded cluster/node-group/Kubernetes state, did a
    full `floci-down.sh` / `floci-up.sh` cycle, and re-derived everything from the
    API rather than from shell variables. Everything survived, including
    `kubectl`'s own connection to the still-running k3s container — the pods never
    even restarted.
12. **`configs/lab-07.env` and verification (Step 23 + Section 9):** wrote all 21
    exports (all populated), then `scripts/utilities/verify-lab-07.sh` (32/32 pass)
    and `scripts/cleanup/lab-07-cleanup.sh`, then committed.

## 6. Results and Evidence

### 6.1 CLI Output

**Evidence 1 — a real k3s control plane, confirmed independently of the AWS API**
```
docker ps: floci-floci-course-eks-usms-eks-cluster   Up   rancher/k3s:latest
kubectl get nodes:
NAME           STATUS   ROLES           VERSION
e14da0f16c1e   Ready    control-plane   v1.34.1+k3s1
```

**Evidence 2 — the full three-tier DNS-based proxy chain, proven end-to-end**
```
GET usms-gateway/            -> {"service":"usms-gateway",...,"routes":["/enrolment/","/results/"]}
GET usms-gateway/enrolment/  -> {"service":"usms-enrolment","pod":"usms-enrolment-...-4nsv4",...}
GET usms-gateway/results/    -> {"service":"usms-results","pod":"usms-results-...-5dj8h",...}
```
(every value in each response — pod name, node name, config values — genuinely
injected at request time; nothing here is a static page)

**Evidence 3 — load genuinely spreads across both enrolment pods**
```
usms-enrolment-...-c9456
usms-enrolment-...-4nsv4
usms-enrolment-...-4nsv4
usms-enrolment-...-c9456
usms-enrolment-...-4nsv4
usms-enrolment-...-4nsv4
```

**Evidence 4 — the ConfigMap/rollback gap, observed exactly as the guide predicts**
```
ConfigMap APP_VERSION changed to 1.1.0  ->  running pods still report "1.0.0"
kubectl rollout restart                 ->  pods now report "1.1.0"
kubectl rollout undo                    ->  pods STILL report "1.1.0" (not 1.0.0)
```
(the Deployment's pod template was correctly reverted; the ConfigMap it references
was not, because rollback only ever reverts what the Deployment itself owns)

**Evidence 5 — two real failures, diagnosed from the actual Events text**
```
Failed to pull image "nginx:this-tag-does-not-exist": ... not found
0/1 nodes are available: 1 Insufficient cpu, Insufficient memory.
```

**Evidence 6 — full persistence across a Floci restart**
```
BEFORE: usms-eks-cluster ACTIVE 1.30 | usms-eks-nodes ACTIVE 2 | 3 deployments 2/1/2 ready
AFTER:  usms-eks-cluster ACTIVE 1.30 | usms-eks-nodes ACTIVE 2 | 3 deployments 2/1/2 ready
        (pod AGE values unchanged — the containers themselves never restarted)
```

**Evidence 7 — `verify-lab-07.sh`**
```
PASS=32 FAIL=0
```

### 6.2 Console Verification

| Console page (real AWS) | CLI substitute used here |
|---|---|
| EKS → Clusters | `aws eks describe-cluster` |
| EKS → Node groups | `aws eks describe-nodegroup` |
| Kubernetes dashboard | `kubectl get all / describe / logs` |

## 7. Analysis and Discussion

`verify-lab-07.sh` passed all 32 checks. Every checkpoint in the guide was
independently confirmed, and — unusually for this course so far — essentially the
entire guide's happy path executed without a single discovered Floci gap on the
scale found in earlier labs. The two genuinely useful findings this lab produced
are both about the *shape* of what this build does, not about something it fails to
do:

**This build runs a real Kubernetes distribution, not a stub.** The guide's own
Section 2 explains that Floci answers `aws eks` calls by manipulating "a genuine,
small Kubernetes distribution... k3s, wrapped by k3d," and this was independently
confirmed rather than taken on faith: `docker ps` shows an actual
`rancher/k3s:latest` container, and every Deployment produced real, separately
scheduled pod containers. This has a direct consequence for how much of this
report can honestly be called "observed" rather than "reasoned about" — per
Section 12.1's own framing, almost every line that the guide lists as merely
"conceptual" on a typical build moved into the "observed" column here, including
the rollout/rollback gap and both deliberate pod failures.

**The absence of separate worker nodes did not become a problem.** `kubectl get
nodes` showed exactly one node — the control-plane node itself — with no separate
agent containers for the "managed node group." This is the precise scenario the
guide flags as expected on some builds and explicitly warns not to treat as a fault
pre-emptively. It never became a problem here because k3s, unlike a
`kubeadm`-provisioned control plane, does not taint its control-plane node against
ordinary workloads by default — every pod in the lab scheduled and ran successfully
on that single node. This is worth recording precisely rather than either ignoring
it or wrongly concluding the node group was non-functional: the AWS-side node group
object is real and `ACTIVE` (confirmed by `describe-nodegroup`), it is simply not
where these particular pods happened to land.

**One minor platform observation:** the end-to-end smoke test (a throwaway
`busybox` pod proxying through the gateway to both backends) failed once,
transiently, immediately after the `floci-down.sh`/`floci-up.sh` restart cycle, and
passed cleanly on every other run including a re-run seconds later. This reads as
ordinary cold-start timing for a freshly-restarted container network rather than a
genuine gap, and is recorded as such rather than treated as a finding.

Beyond the Floci-specific observations, the exercises themselves were pedagogically
sharp: forcing the rollback-doesn't-revert-everything gap by actually running the
sequence (rather than reading about it) is a materially different, stronger piece
of evidence than the guide's own prose, and the two deliberate failures produced
exactly the `Events` text the guide predicts, verbatim.

## 8. Reflection

**1. What did you learn about this AWS service?**
That EKS's real cost, relative to Fargate-backed ECS, is entirely in getting a data
plane back: two IAM roles with an easily-inverted trust distinction, and a node
group whose sizing is now a decision nobody was asking me to make in Lab 04. What
you get in exchange — observed directly, not read about — is a service-discovery
mechanism (cluster DNS) that needed zero additional AWS objects, where Lab 05's ALB
equivalent needed an entire load-balancer stack.

**2. What challenges did you encounter?**
Getting the `kubectl run --rm` invocation right in a non-interactive script context
took real debugging (`--rm` requires an attached mode, so a bare `--rm` without `-i`
fails outright) — a small but genuine Kubernetes CLI subtlety distinct from
anything Floci-specific. More substantively: resisting the urge to just read the
guide's described rollback gap rather than actually reproducing it, since actually
running the sequence surfaced the exact wording of the discrepancy rather than an
assumed one.

**3. How would you apply this service in a real-world cloud environment?**
Exactly as built here for a genuinely multi-team, multi-service organisation: IRSA
rather than a shared node role for pod-level AWS permissions (Step 21 explains
precisely why this build couldn't demonstrate it — no reachable OIDC issuer — but
the chain is fully specified and ready to apply on real AWS), and a GitOps-managed
release process that treats configuration and workload as one versioned unit, which
Review Question 4's rollback gap makes a concrete case for rather than an abstract
best practice.

**4. What additional concepts or features would you like to explore?**
Real IRSA end-to-end (this build's lack of a reachable OIDC issuer blocked it
entirely), Kubernetes NetworkPolicies to make the namespace boundary Step 12
explicitly says is *not* an isolation boundary into one, and a cluster autoscaler —
mentioned in Step 10 as something Lab 08 discusses but does not install.

## 9. Conclusion

This practical's objectives were fully achieved, and on a build that turned out to
be unusually capable: a real EKS cluster (backed by a genuine k3s distribution,
independently confirmed) and a real managed node group were created via the AWS
CLI, and three interdependent microservices were deployed declaratively and proven
to discover each other by DNS name alone — no addresses anywhere in the gateway's
configuration, and the full proxy chain verified end-to-end with real, injected pod
identity in every response. The rolling-update/rollback exercise surfaced a precise,
reproducible gap (a Deployment rollback reverts its own template but not a
ConfigMap it merely references) by actually running the sequence rather than
reading about it, and two deliberately broken pods produced exactly the diagnostic
evidence the guide predicts. Persistence across a full Floci restart was proven by
re-deriving every identifier from the API, and the restart didn't even disturb the
running containers. Seven labs into this course, the same discipline holds: observe
precisely, distinguish what you saw from what you reasoned about, and say so plainly
when a build turns out to be more — or less — capable than expected.

## 10. Appendix

**Reproduce this lab:**
```bash
source ~/aws-floci-course/configs/course.env
./scripts/setup/floci-up.sh
source ~/aws-floci-course/configs/lab-01.env
source ~/aws-floci-course/configs/lab-02.env
source ~/aws-floci-course/configs/lab-07.env
aws eks update-kubeconfig --name usms-eks-cluster --alias usms-eks
./scripts/utilities/verify-lab-07.sh
```

**Resource identifiers (also in `configs/lab-07.env`):**

| Resource | Value |
|---|---|
| Cluster | `usms-eks-cluster` (ACTIVE, k8s 1.30, 4 subnets, `_lb_ports_=8081,8082`) |
| Node group | `usms-eks-nodes` (ACTIVE, private subnets only, min 2 / max 4 / desired 2) |
| Cluster role | `usms-eks-cluster-role` + `USMSEKSClusterPolicy` |
| Node role | `usms-eks-node-role` + `USMSEKSNodePolicy` + `USMSStudentDataReadWrite` |
| Namespace | `usms` |
| Deployments | `usms-gateway` (1), `usms-enrolment` (2), `usms-results` (2) |

**Supplementary files:**
- Manifests: [`manifests/lab-07/`](../../manifests/lab-07/)
- Policies: [`policies/trust-eks-cluster.json`](../../policies/trust-eks-cluster.json),
  [`policies/trust-eks-node.json`](../../policies/trust-eks-node.json),
  [`policies/usms-eks-cluster-policy.json`](../../policies/usms-eks-cluster-policy.json),
  [`policies/usms-eks-node-policy.json`](../../policies/usms-eks-node-policy.json)
- Templates: [`templates/lab-07-create-cluster.json`](../../templates/lab-07-create-cluster.json),
  [`templates/lab-07-create-nodegroup.json`](../../templates/lab-07-create-nodegroup.json)
- Scripts: [`scripts/utilities/verify-lab-07.sh`](../../scripts/utilities/verify-lab-07.sh),
  [`scripts/cleanup/lab-07-cleanup.sh`](../../scripts/cleanup/lab-07-cleanup.sh)
- Environment config: [`configs/lab-07.env`](../../configs/lab-07.env)
- Review questions: [`notes/lab-07-notes.md`](../../notes/lab-07-notes.md)

---

### Submission Checklist

- [x] Aim/Objectives clearly stated
- [x] Introduction provided
- [x] Real-world use case described
- [x] System architecture included
- [x] All implementation steps documented
- [x] CLI output captured as evidence
- [x] Console verification — *N/A for Floci; kubectl-substitute table provided*
- [x] Analysis and discussion completed
- [x] Reflection completed
- [x] Conclusion written
- [x] Appendix attached

---

## Problems I hit and how I fixed them

- **`kubectl run ... --rm` with no `-i` fails outright** with `error: --rm should
  only be used for attached containers` — not a Floci quirk, a genuine `kubectl`
  requirement. Fixed by adding `-i` to every throwaway-pod command used inside the
  verification script.
- **The end-to-end smoke test failed once, transiently, immediately after the
  Floci restart** and passed cleanly on every other run. Read as cold-start timing
  for the container network rather than a genuine gap, and recorded as such rather
  than either hidden or over-claimed as a finding.
- **Corrected an obvious copy-paste artifact in the namespace manifest** (the
  source guide's own `lab: "05a"` label, clearly left over from an earlier lab
  template) to `lab: "07"` rather than reproducing the error faithfully.
- **`kubectl get nodes` showed only the control-plane node, no separate agents** —
  the exact scenario the guide warns might happen and says not to treat as a fault
  pre-emptively. Confirmed it genuinely wasn't one: every pod in the lab scheduled
  and ran successfully on that single node, because k3s does not taint its
  control-plane node against ordinary workloads the way a `kubeadm` cluster does.
