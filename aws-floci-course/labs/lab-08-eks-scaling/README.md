# Lab 08 — EKS Scaling and Service Exposure

**Support path: A** — real `kubectl` against the real k3s cluster built in Lab 07.
Every object in this report (the HPA, the load generator, both PodDisruptionBudgets,
the NodePort/LoadBalancer Services, the Ingress) was created and verified against
that live cluster, not designed on paper.

## What this lab built

- `usms-enrolment-hpa` — `autoscaling/v2`, min 2 / max 8, target 50% CPU of the
  container's `50m` request, with an asymmetric `behavior` block (instant,
  rate-limited scale-up; a 300-second stabilisation window on scale-in)
- `usms-loadgen` — three `busybox` pods looping `wget` against the gateway,
  used to drive the HPA under genuine load
- node group `usms-eks-nodes` rescale attempted via the AWS side (min 2 / max 6 /
  desired 3) — **this specific call fails on this build**, see Finding 2 below
- `nodeSelector: workload: usms` on `usms-enrolment`, with enforcement proven
  against a deliberately bad value
- `usms-gateway-pdb` (`minAvailable: 1`) and `usms-enrolment-pdb`
  (`maxUnavailable: 1`), with the eviction-API-vs-plain-delete contrast proven
- the full exposure ladder: ClusterIP (already existing) → `kubectl port-forward`
  → `usms-results-np` (NodePort, pinned 30080) → `usms-gateway` promoted to
  LoadBalancer → `usms-portal-ingress` (three prefix paths)

## Findings worth reading before the verify output

### 1. The guide's own metrics-availability check gives a false negative

`kubectl get --raw /apis/metrics.k8s.io/v1beta1` returns
`Error from server (NotFound)` on this build — which reads exactly like "no
metrics pipeline." But `kubectl top nodes`/`kubectl top pods` both succeed
immediately with real per-pod figures, and the HPA created immediately
afterward read a working `cpu: 2%/50%` on its very first poll. The bare
API-group discovery path does not resolve on this k3s build even though the
pipeline underneath it is fully functional. `kubectl top` — which the guide
itself calls "the single diagnostic" — is the one to trust; its own suggested
raw-path check is not, on this build.

### 2. A new Floci gap: `update-nodegroup-config` is misrouted to S3's validator

```
aws eks update-nodegroup-config --cluster-name usms-eks-cluster \
    --nodegroup-name usms-eks-nodes --scaling-config minSize=2,maxSize=6,desiredSize=3

An error occurred (400) when calling the UpdateNodegroupConfig operation:
<?xml version="1.0" encoding="UTF-8"?><Error><Code>InvalidArgument</Code>
<Message>POST requires either ?uploads, ?uploadId, ?restore or ?select
parameter.</Message>...
```

That is an S3 multipart-upload validation error, not anything EKS would ever
return. Retried once, identical result; `describe-nodegroup` confirmed the
scaling configuration never changed (`minSize=2,maxSize=4,desiredSize=2`
throughout). This is a distinct category from every Floci gap recorded in
Labs 05–07: not `UnknownOperationException` (the whole operation is
unrecognised, as with Application Auto Scaling), not `UnsupportedOperation`
(a named but unimplemented call), and not a silent accept-then-drop (Lab 05's
health-check grace period). Here the call appears to be dispatched to the
wrong emulated service's request handler entirely. Recorded honestly in
`configs/lab-08.env` (the three `USMS_NODEGROUP_*` values reflect the
*unchanged* configuration) and in `verify-lab-08.sh` (one explicitly
documented `FAIL`), per the same intellectual-honesty standard Lab 06 set for
Path C.

### 3. An unplanned infrastructure incident, and a stronger persistence proof than Step 18 asked for

Mid-lab, Docker Desktop required a restart. The EKS emulation container came
back up but its embedded k3s crashed repeatedly with
`failed to find interface with specified node ip` — k3s's own persisted
Node-object state expected address `172.17.0.3` (the container's address
during all of Lab 07/08's prior work), but Docker's default `bridge` network
reassigned it `172.17.0.2` on reconnect, since nothing else had claimed the
pool in the interim. The address can't be pinned directly on Docker's default
bridge network (`"user-specified IP address is supported on user-defined
networks only"`), so the fix was to start a disposable placeholder container
on the same network first — claiming `172.17.0.2` — so Docker's sequential
allocator gave the real container `172.17.0.3` on its next connect, matching
what k3s's state expected. It started cleanly immediately afterward.

Every Lab 08 object — the HPA's bounds, both PDBs, the pinned NodePort, the
LoadBalancer's allocated nodePort, and the Ingress's three paths — survived
this full, unplanned crash-and-recover cycle with zero data loss, which is a
strictly stronger proof than the course's own prescribed `floci-down.sh` /
`floci-up.sh` cycle (also run afterward, as Step 18 asks, and also producing a
byte-identical diff — see `outputs/lab-08-before-restart.txt` and
`outputs/lab-08-after-restart.txt`).

### 4. Two host-port collisions with unrelated local containers, investigated rather than assumed

`curl http://localhost:30080/` answered on the first attempt — but with a
generic nginx welcome page, not this lab's JSON. `docker ps --filter
publish=30080` named the real owner: `dso202-control-plane`, an unrelated
course's `kind` cluster bound to that same host port on this machine. The EKS
container's own `docker port` output confirmed it publishes only
`6443->6500` — the NodePort genuinely is not host-reachable, exactly as the
guide's own Floci Limitation predicts, and the first result was a coincidental
false positive from a different container, not evidence against the
limitation. A second attempt at the port-forward fallback collided again
(`30081`, an unrelated local dev server); resolved by confirming a free port
first (`netstat -ano`) before retrying successfully.

### 5. An MSYS path-mangling bug, caught a second time in this course — now on a raw API path

`kubectl create --raw "/api/v1/namespaces/usms/pods/$POD/eviction" -f ...`
failed with a plain `404`. Verbose output showed Git Bash had rewritten the
leading `/api/v1/...` into `/Program Files/Git/api/v1/...` — the same class of
bug first caught on `--health-check-path /` in Lab 05, now recurring on a raw
API path argument rather than a CLI flag. Fixed with `MSYS_NO_PATHCONV=1`,
after which the eviction correctly returned `TooManyRequests: Cannot evict pod
as it would violate the pod's disruption budget`.

### 6. Corrections to the source material

The HPA, load generator and Ingress manifests in the published guide all
carried `lab: "05b"` — a leftover draft-numbering artifact, the same kind
caught in Lab 07's `lab: "05a"` namespace typo. Corrected to `lab: "08"` in
all three manifests actually applied.

### 7. No Ingress controller — with a specific, confirmed reason

`kubectl get ingressclass` returned nothing and no Traefik/nginx pod exists
anywhere in the cluster. `docker inspect`'s `Config.Cmd` for the EKS container
names the reason precisely: `k3s server --disable=traefik ...` — this build's
k3s explicitly disables the ingress controller it would otherwise bundle by
default. The Ingress object itself is created, stored, and correctly resolves
all three paths against live Service endpoints (visible in `kubectl describe
ingress`'s `Backends` column) — it simply has nothing acting on it, which is
a complete and true description of the object's state, not a partial one.

## What was genuinely observed vs. recorded vs. conceptual

**Observed directly:** manual and declarative scaling with the drift between
them; endpoints growing only on pod readiness and shrinking before SIGTERM;
QoS classes and the scheduler's allocated-resources arithmetic;
Guaranteed↔Burstable pod replacement (not adjustment); the HPA computing a
percentage of the *request* and genuinely scaling 2→3→2 under real load, event
reasons quoted verbatim; the 300-second stabilisation window holding capacity
after load stopped; nodeSelector enforcement with a deliberately bad value;
`maxUnavailable: 0` protecting running pods during a stuck rollout; a PDB
refusing an eviction and a plain delete ignoring it; ClusterIP unroutable from
the host; NodePort answering correctly via the documented fallback once two
unrelated port collisions were ruled out; a LoadBalancer Service receiving a
real external address; an Ingress with three correctly-routed paths and no
controller to act on them.

**Recorded but not enacted:** the node group's scaling configuration (Finding
2 — this call fails outright on this build, more severe than "recorded but
ignored"); the AWS load-balancer annotations on the Service and Ingress.

**Conceptual only:** the AWS Load Balancer Controller turning the Ingress into
a real ALB; Cluster Autoscaler and Karpenter (both need IRSA, confirmed
unavailable since Lab 07); custom/external metrics for the HPA; scheduled
scaling, quotas and real cost.

## Step 17 comparison and review questions

See `notes/lab-08-notes.md` for the full ECS/AAS-vs-EKS/HPA and
ALB-vs-Ingress comparison tables, the two prose paragraphs Step 17 asks for,
and the review-question answers (Section 15's actual question text did not
survive the course PDF's extraction — answered from the topics the guide
itself references by number in later steps).

## Verification

`scripts/utilities/verify-lab-08.sh`: **PASS=33 FAIL=1**, with the one `FAIL`
being the documented, expected node group `maxSize` check (Finding 2 — not a
gap in this lab's own work, a confirmed Floci defect).
