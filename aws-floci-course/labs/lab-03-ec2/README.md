# AWS Practical Laboratory Report — Lab 03: Elastic Compute Cloud (EC2)

## 1. Aim / Objective

To launch a two-tier compute deployment for the University Student Management System
(USMS) on Amazon EC2 — a web-tier instance in a public subnet and a data-tier instance
in a private subnet — using the AWS CLI against a local AWS emulator (Floci), consuming
the IAM instance profile from Lab 01 and the VPC, subnets and security groups from
Lab 02, and to verify placement, permissions, bootstrapping, addressing, storage and
persistence throughout.

## 2. Introduction

Amazon EC2 is AWS's virtual-server service. A running instance is the combination of
three independent things: an **AMI** (an immutable template for the root disk plus
metadata — architecture, virtualisation type, block-device layout), an **instance
type** (the hardware shape — vCPU count, memory, network bandwidth, and whether local
instance storage exists), and **user data** (an optional script that cloud-init runs
once, as root, at first boot). None of the three is sufficient on its own; "launching an
instance" is the act of combining them with a network placement (subnet, security
group) and, optionally, an identity (instance profile) into one running system.

**Key features used in this practical:**
- AMI selection — read programmatically from the account's own catalogue, never
  hard-coded
- EC2 key pairs — the private half shown exactly once, redirected straight to a file
- User data — a bootstrap script, with the quoting rule that decides whether a variable
  expands on the laptop writing it or on the instance running it
- `--generate-cli-skeleton` / `--cli-input-json` — turning a 50-plus-parameter API call
  into a reviewable JSON document under version control
- Elastic IP addresses — a stable, account-owned address, decoupled from any one
  instance's lifecycle
- EBS volumes — durable block storage with a hard Availability-Zone constraint
- AMIs built from a running instance — baking configuration in, rather than installing
  it at every boot

IAM (Lab 01) and VPC (Lab 02) are both prerequisites that this lab consumes rather than
builds: the instance profile created in Lab 01 and attached to no instance until now,
and the subnet/security-group pair built in Lab 02 and populated by nothing until now,
both become load-bearing in a single `run-instances` call here.

## 3. Use Case

USMS needs two tiers of compute, built on the Lab 02 network:

| Tier | Instance | Subnet | Identity | Reachable from internet? |
|---|---|---|---|---|
| Web | `usms-web-01` | `usms-public-subnet-a` | `usms-ec2-app-profile` | Yes — 80/443 via `usms-app-sg`, stable address via Elastic IP |
| Data | `usms-db-01` | `usms-private-subnet-a` | none | No — outbound only, via NAT; `usms-db-sg` admits only the web tier |

The web tier is given an instance profile (not an access key) so that it can later
write to S3 (Lab 04) with no credential ever stored on disk. The data tier is given no
identity at all, on the principle that a tier with no reason to call an AWS API should
have no ability to.

## 4. System Architecture / Design

```
                         usms-vpc  (10.0.0.0/16)
                                │
        ┌───────────────────────┴────────────────────────┐
  usms-public-subnet-a                            usms-private-subnet-a
  10.0.1.0/24  us-east-1a                          10.0.3.0/24  us-east-1a
        │                                                   │
  usms-web-01  t3.micro                             usms-db-01  t3.micro
    ├── usms-app-sg        (80,443 <- 0.0.0.0/0;             ├── usms-db-sg   (5432 <- usms-app-sg)
    │                       22 <- 10.0.0.0/16)                ├── no public address
    ├── usms-ec2-app-profile -> usms-ec2-app-role             ├── no instance profile
    │     -> USMSStudentDataReadWrite                         └── outbound only, via usms-nat
    │        (names a bucket that does not exist until Lab 04)
    ├── usms-web-eip  (Elastic IP, stable, account-owned)
    └── usms-web-data-vol  (8 GiB gp3, same AZ as the instance,
                             independent lifecycle from the root volume)

Permission chain proven in Step 11:
  instance -> IamInstanceProfile.Arn -> usms-ec2-app-profile
           -> InstanceProfile.Roles[0] -> usms-ec2-app-role
           -> AttachedPolicies -> USMSStudentDataReadWrite
           -> s3:GetObject/PutObject/ListBucket on arn:aws:s3:::usms-student-data(/*)

Reachability chain proven in Step 14 (6 of 7 links are AWS configuration,
checked by describe-* calls; the 7th — a process listening on :80 — is not):
  browser -> IGW -> public route table -> subnet -> NACL -> ENI -> security group
          -> instance running -> [process on :80, unverifiable on this build]
```

## 5. Implementation Procedure

All work was performed against **Floci** (Account ID `000000000000`), continuing
directly from the IAM foundation (Lab 01) and the VPC (Lab 02).

0. **Rebuilt Labs 01 and 02 against this machine's Floci instance.** This repository
   was moved to a new machine between Lab 02 and Lab 03; the committed `configs/*.env`
   files recorded resource IDs from a Floci instance that no longer existed on this
   host — `aws ec2 describe-vpcs` showed only the default VPC. Before any Lab 03 work
   could begin, Labs 01 and 02's resources were re-created against this machine's fresh
   Floci container, following the exact names, policies and architecture already
   documented in those labs' own reports. Because IAM resource ARNs are name-derived,
   `configs/lab-01.env` needed no changes; because EC2/VPC resource IDs are randomly
   generated per-creation, `configs/lab-02.env` and `policies/usms-db-sg-ingress.json`
   were regenerated with the new IDs and committed separately. `verify-lab-01.sh`
   (34/34) and `verify-lab-02.sh` (49/49) both confirmed a clean rebuild before Lab 03
   started.
1. **Environment (Step 1):** Started Floci, sourced `course.env`, `lab-01.env`,
   `lab-02.env`, confirmed identity with `whoami.sh`.
2. **Network intact (Step 2):** Re-ran `verify-lab-02.sh` — `PASS=49 FAIL=0`.
3. **AMI selection (Step 3):** `describe-images --owners amazon` returned a small,
   realistic catalogue (an Amazon Linux 2 image, an Amazon Linux 2023 image, Debian,
   Alpine, and Windows Server) — this Floci build seeds images, so neither of the
   guide's `register-image`/placeholder fallbacks was needed. Selected the Amazon
   Linux 2023 image, to match `user-data.sh`'s use of `dnf`. The SSM public-parameter
   technique (`/aws/service/ami-amazon-linux-latest/...`) was also attempted, per the
   guide's instruction to try it regardless; see Section 7 for what actually happened.
4. **Key pair (Step 4):** Created `usms-app-key`, redirected the private key straight
   to `outputs/usms-app-key.pem`.
5. **Git-ignore proof (Step 5):** Confirmed via `git check-ignore -v` (matched by the
   repository's existing `*.pem` rule) and `git ls-files outputs/` (lists only
   `.gitkeep`).
6. **User-data script (Step 6):** Wrote `labs/lab-03-ec2/user-data.sh` — installs
   `nginx` via `dnf`, reads the instance's own identity from IMDSv2, and writes a
   small status page and a `health.json` endpoint. `bash -n` passed; 1,657 bytes,
   comfortably under the 16 KB limit.
7. **Request as a reviewable document (Step 7):** Generated the full
   `run-instances --generate-cli-skeleton` (230 lines; not committed — see Section 6
   of the guide and Section 7 below), then wrote the actual request,
   `templates/lab-03-run-instances.json`, with real subnet/security-group/profile IDs
   substituted in and validated as JSON.
8. **Launch `usms-web-01` (Step 8):** One `run-instances` call combining
   `--cli-input-json` with `--user-data file://...`, consuming Lab 01's instance
   profile and Lab 02's subnet and security group.
9. **Wait for running (Step 9):** `aws ec2 wait instance-running` hung past its
   120-second allowance on this build; fell back to the guide's own manual polling
   loop, which reached `running` after roughly 30 seconds — see Section 7 for why this
   diverges from the guide's "almost instant" claim.
10. **Read the instance back (Step 10):** Pulled the six fields that matter via one
    multi-line `--query` projection.
11. **Trace the permission chain (Step 11):** instance → `IamInstanceProfile.Arn` →
    `usms-ec2-app-profile` → `usms-ec2-app-role` → `USMSStudentDataReadWrite`, captured
    to `outputs/lab-03-instance-policy.json`.
12. **Prove user data arrived (Step 12):** Attempted the full round-trip
    (`describe-instance-attribute --attribute userData`, `openssl base64 -d`, `diff`).
    See Section 7 — this Floci build does not return a `UserData` field at all.
13. **Elastic IP (Step 13):** Allocated and associated `usms-web-eip`.
14. **Test the application (Step 14):** `curl` timed out, exactly as the guide
    anticipates on Floci. Ran the fallback six-link reachability chain — all six
    configuration links check out.
15. **Data volume (Step 15):** Created `usms-web-data-vol` (8 GiB, `gp3`) in the
    instance's own Availability Zone and attempted `attach-volume`. See Section 7 — it
    returns `UnsupportedOperation` unconditionally on this build; the volume exists,
    correctly placed, but was never attached. The guide's "Your Turn" cross-AZ mismatch
    test was not attempted, since the baseline operation does not work on this build.
16. **Launch `usms-db-01` (Step 16):** Long-form `run-instances` into
    `usms-private-subnet-a` with `usms-db-sg` and deliberately **no** instance profile.
17. **Prove the two-tier wiring (Step 17):** Confirmed each instance's security group,
    the private route table's NAT-only default route, and attempted the group-to-group
    source check on `usms-db-sg` (reproduces the exact `UserIdGroupPairs`-not-persisted
    gap Lab 02 already documented).
18. **Stop/start `usms-web-01` (Step 18):** Stopped, confirmed state, restarted, and
    checked the Elastic IP and private address across the cycle.
19. **Restart persistence (Step 19):** Recorded instance/subnet/security-group
    associations by tag, restarted Floci itself, and diffed — identical.
20. **Golden AMI (Step 20):** Attempted `create-image` from `usms-web-01`. See
    Section 7 — also `UnsupportedOperation` on this build.
21. **Audit (Step 21):** Tabulated every instance, volume and Elastic IP tagged
    `Project=USMS`.
22. **`configs/lab-03.env` (Step 22):** Captured every real identifier by lookup, not
    from shell variables — including discovering and working around a `describe-addresses
    --filters` bug while doing so (Section 7).
23. **Verification and commit (Step 23):** Wrote `scripts/utilities/verify-lab-03.sh`
    (30 automated checks, 5 documented informational gaps) and
    `scripts/cleanup/lab-03-cleanup.sh`, then committed.

## 6. Results and Evidence

### 6.1 CLI Output

Floci is CLI-only — there is no browser or desktop session to screenshot in this
environment, so the evidence below is the literal, unedited output captured while each
command ran, in place of a pasted screenshot. This is the same evidentiary standard
Labs 01 and 02 used (a CLI-substitute table in place of an AWS Console); here the
substitution is a transcript in place of a screenshot of a terminal, carrying the same
information.

**Evidence 1 — Instance launched, reading back the fields that matter (Step 10)**
```
+-----------+--------------------------------------------------------------------+
|  AZ       |  us-east-1a                                                        |
|  Id       |  i-586eeca96aa9b0754                                               |
|  Key      |  usms-app-key                                                      |
|  Profile  |  arn:aws:iam::000000000000:instance-profile/usms-ec2-app-profile   |
|  SG       |  usms-app-sg                                                       |
|  State    |  running                                                           |
|  Subnet   |  subnet-5e1fd5a1                                                   |
|  Type     |  t3.micro                                                          |
+-----------+--------------------------------------------------------------------+
```

**Evidence 2 — Permission chain traced to the policy document (Step 11)**
```
1. instance -> profile : arn:aws:iam::000000000000:instance-profile/usms-ec2-app-profile
2. profile  -> role    : usms-ec2-app-role
4. role -> policy document:
{
    "Statement": [
        { "Sid": "ListTheBucketItself", "Resource": "arn:aws:s3:::usms-student-data", ... },
        { "Sid": "ReadWriteObjectsInsideTheBucket", "Resource": "arn:aws:s3:::usms-student-data/*", ... },
        { "Sid": "NeverDeleteTheBucket", "Effect": "Deny", "Action": ["s3:DeleteBucket"], ... }
    ]
}
```
(full document captured to `outputs/lab-03-instance-policy.json`, git-ignored)

**Evidence 3 — Elastic IP allocated and associated (Step 13)**
```
alloc=eipalloc-15bc32609094705a6  assoc=eipassoc-8aa8e73b090b95f65  address=54.96.140.123
```

**Evidence 4 — Six-link reachability chain, all configuration links pass (Step 14)**
```
== 1. Is the instance running? ==            running
== 2. Route table reaches an IGW? ==          igw-c1d0a567
== 3. Is that IGW attached? ==                available
== 4. SG admits tcp/80 from the internet? ==  0.0.0.0/0
== 5. Public address present? ==              127.0.0.1 (see Section 7 — Floci quirk, not a real routable address)
== 6. NACL would allow it? ==                 acl-ceee0cf805cac8d20  True
```

**Evidence 5 — `usms-db-01` wired as the private, no-profile data tier (Step 16/17)**
```
+-------------+---------------+-------------------+
|    Name     |      SG       |      Subnet       |
+-------------+---------------+-------------------+
|  usms-web-01|  usms-app-sg  |  subnet-5e1fd5a1  |
|  usms-db-01 |  usms-db-sg   |  subnet-c07d86ae  |
+-------------+---------------+-------------------+
Private route table default route -> nat-af77e23d99535b8bb (not an IGW)
```

**Evidence 6 — Elastic IP and private address survive stop/start (Step 18)**
```
before: web=127.0.0.1  (auto-assigned address, pre-EIP baseline)
stopped: Public=127.0.0.1  Private=172.22.0.3
started: Public=127.0.0.1  Private=172.22.0.3
describe-addresses: 54.96.140.123 still associated with i-586eeca96aa9b0754
```
(Private address and instance ID never changed across the cycle; see Section 7 for
why the public field itself does not visibly change on this build.)

**Evidence 7 — Full Floci restart, instances/subnets/security-groups unchanged (Step 19)**
```
PERSISTENCE PROVEN: same instances, same subnets, same security groups after restart
```

**Evidence 8 — `verify-lab-03.sh`, end-to-end (Step 23)**
```
PASS=30 FAIL=0 INFO=5
```
(the 5 `(i)` lines are the discovered Floci gaps in Section 7, each individually
confirmed by retrying the underlying AWS call in isolation — not assumed from one
run)

### 6.2 Console Verification

As in Labs 01 and 02, Floci has no AWS Management Console. The CLI-substitute table:

| Console page (real AWS) | CLI substitute used here |
|---|---|
| EC2 → Instances | `aws ec2 describe-instances` |
| EC2 → AMIs | `aws ec2 describe-images --owners amazon\|self` |
| EC2 → Key Pairs | `aws ec2 describe-key-pairs` |
| EC2 → Elastic IPs | `aws ec2 describe-addresses` |
| EC2 → Volumes | `aws ec2 describe-volumes` |
| EC2 → Instance → Actions → Instance Settings → Edit user data | `aws ec2 describe-instance-attribute --attribute userData` |

## 7. Analysis and Discussion

`verify-lab-03.sh` passed all 30 automated checks that this build can actually
support, with 5 informational findings recorded rather than hidden. Every checkpoint
in the guide (1 through 8) was independently confirmed against real command output.

**This Floci build is substantially more capable than the course guide assumes it to
be, which is itself the most interesting finding of the lab.** The guide's own "Floci
Limitation" callouts, written for a typical build, state flatly that Floci "does not
boot a real operating system for every instance." That is false for this specific
build. Reading `docker logs floci` while `usms-web-01` launched showed Floci actually
pulling `public.ecr.aws/amazonlinux/amazonlinux:2023`, starting a real Docker
container for the instance, starting two `socat` sidecar containers to port-forward
80 and 443 from the host, and genuinely executing the user-data script inside that
container (`UserData shellscript part 1/1 completed`). The reason `curl` to the
instance's address still fails is not "no OS" — it is that the sandboxed per-instance
container has **no outbound DNS/internet access**, so `dnf -y install nginx` fails
with `Could not resolve host: cdn.amazonlinux.com`, and nginx is never installed. The
practical consequence for the lab's assessed outcome is identical to what the guide
predicts (the application is unreachable), but the actual cause is different and more
specific, and is worth recording precisely rather than accepting the guide's generic
explanation uncritically — which is the whole discipline this course has been building
since Lab 01.

**Six further gaps were found, each independently confirmed by retrying the
underlying call in isolation rather than accepted from a single result:**

1. **`attach-volume` returns `UnsupportedOperation` unconditionally.** The volume
   itself creates correctly, in the correct Availability Zone, and reads back as
   `available` — only the attach call is rejected, every time, with no parameter
   combination tried succeeding. This contradicts the guide's own Floci-vs-Real-AWS
   table, which lists EBS attach/detach as fully implemented.
2. **`create-image` returns `UnsupportedOperation` unconditionally**, for the same
   reason. No golden AMI exists; `configs/lab-03.env` records `USMS_WEB_AMI` as
   deliberately blank, with a comment, rather than inventing a placeholder ID. Lab 08's
   launch template will need to address this when it is reached.
3. **`describe-instance-attribute --attribute userData` returns no `UserData` field at
   all** — confirmed with an unfiltered `--output json` call, which showed only
   `{"InstanceId": "..."}`. `run-instances --user-data file://...` is accepted without
   error, so the script is plausibly stored somewhere (and, per the finding above, it
   really was executed), but Step 12's byte-for-byte proof cannot be performed through
   this API on this build.
4. **Every instance is given `PublicIpAddress: 127.0.0.1`, regardless of the subnet's
   `MapPublicIpOnLaunch` setting.** `usms-db-01`, in the private subnet (confirmed
   `MapPublicIpOnLaunch=False`), still reads `127.0.0.1` rather than `None`. This
   address is Floci's own host-loopback port-forwarding endpoint, not a real public or
   private AWS address, and it is assigned identically to both tiers. This is exactly
   the benign-failure mode the guide's Section 9.2 anticipates by name, and
   `verify-lab-03.sh` records it as informational rather than failing the check,
   consistent with that precedent.
5. **Root EBS volumes created implicitly by `run-instances` do not receive the
   `TagSpecifications` entry for `ResourceType: volume`**, even though both launches in
   this lab included one. Only the volume created explicitly with `create-volume`
   (`usms-web-data-vol`) carries its tags; `usms-web-01` and `usms-db-01`'s own root
   volumes are untagged. The guide itself warns, in Lab 02's context, that "untagged
   volumes are how orphaned storage accumulates in real accounts" — here that exact
   outcome occurs not from a mistake but from the API silently dropping a
   correctly-formed request.
6. **`describe-addresses --filters "Name=tag:Name,Values=..."` ignores the filter and
   returns every address**, rather than an empty result or an error. This was caught
   while writing `configs/lab-03.env`: a query for `usms-web-eip` specifically returned
   `usms-nat-eip`'s allocation ID and address instead, because `[0]` on the unfiltered
   list happened to select the wrong entry. This is the same category of gap Lab 02
   documented for `describe-network-acls`/`describe-security-groups` — tag- and
   ID-based server-side `--filters` are unreliable on this build across multiple EC2
   describe-\* calls — and was worked around the same way: unfiltered list plus
   client-side `--query` filtering on the tag value itself.

**Two further quirks were platform-, not Floci-, specific**, and are recorded because
they cost real debugging time:

- `chmod 600 outputs/usms-app-key.pem` reports success and `stat -c '%a'` still reads
  `644` on this Windows/Git-Bash environment, because Git Bash's POSIX-permission
  emulation over NTFS does not reflect an ACL change made through `chmod`. The actual
  security control applied here was `icacls ... /inheritance:r /grant:r
  "<user>:(R,W)"`, which does restrict the file to the owning Windows account — the
  real control is correct, but the POSIX-style check in `verify-lab-03.sh` cannot see
  it and is recorded as informational rather than failing.
- `python3` resolves to a Windows "App Execution Alias" stub that does not run the
  real interpreter in this Git-Bash environment, even though `command -v python3`
  finds it; `python` (without the `3`) is the actual CPython 3.14 installation and is
  what `verify-lab-03.sh` and this lab's commands use for `-m json.tool`.

None of the above required changing the actual compute design — every finding was
either a corrective technique (the `describe-addresses` filter workaround, the
`icacls` fix) or a documented, independently-confirmed limitation of this specific
Floci build, recorded rather than fought, exactly as Labs 01 and 02 established as the
house style for this course.

## 8. Reflection

**1. What did you learn about this AWS service?**
That an EC2 instance is not one thing but the composition of at least five
independent, separately-lifecycled objects — an AMI, an instance type, a network
placement, an identity, and (optionally) user data — and that `run-instances` is the
single call where previously-built, unrelated artefacts from two earlier labs become
load-bearing simultaneously. I also learned, more by accident than design, that an
emulator's documented limitations and its actual limitations can differ: this Floci
build genuinely boots containers and executes user data, which the guide's own
reference table says it does not — a reminder that "the guide says X" and "I verified
X" are not the same sentence, which is the exact discipline Lab 01 introduced and this
lab kept applying.

**2. What challenges did you encounter?**
Distinguishing a genuine emulator gap from my own mistake took the most time — the
`describe-addresses --filters` bug looked, at first glance, exactly like a bug in my
own `--query` expression, and was only confirmed as a Floci-side issue by comparing
the filtered and unfiltered calls side by side. The second challenge was resisting the
guide's own stated expectation (`curl` will simply time out, full stop) once the Docker
logs showed a much more specific and more interesting mechanism actually at work.

**3. How would you apply this service in a real-world cloud environment?**
Exactly the pattern built here, plus the pieces this Floci build could not actually
exercise: a real golden-AMI pipeline (Step 20's intent) feeding an Auto Scaling group
(Lab 08), EBS volumes that genuinely enforce the AZ constraint rather than returning
`UnsupportedOperation`, and IMDSv2-sourced temporary credentials replacing the
instance-profile *association* this lab could only prove existed, not actually use.

**4. What additional concepts or features would you like to explore?**
Launch templates and versioning, instance metadata options (`HttpTokens: required`
to enforce IMDSv2 account-wide), EBS snapshot lifecycle policies, and Nitro-based
instance types' hardware-level isolation — none of which this emulator's gaps left
room to exercise meaningfully here.

## 9. Conclusion

This practical's objectives were achieved within the real limits of this specific
Floci build: a two-tier compute deployment — `usms-web-01` in the public subnet with
an Elastic IP, Lab 01's instance profile, and Lab 02's security group; `usms-db-01` in
the private subnet with no public address and no profile — was launched entirely via
the AWS CLI, its permission chain traced to a named S3 policy, its network wiring
proven correct on both the security-group and routing layers, and its persistence
proven across both an instance stop/start and a full Floci restart. `attach-volume` and
`create-image` were discovered to be unconditionally unsupported on this build, and are
recorded as such rather than worked around with a fabrication; five further gaps were
independently confirmed and documented with the same rigor Labs 01 and 02 established.
The most significant finding — that this build actually boots real per-instance
Docker containers and executes user data, failing only for lack of outbound network
access — is a direct product of checking the guide's own claim rather than accepting
it, which remains this course's central lesson three labs in.

## 10. Appendix

**Reproduce this lab:**
```bash
source ~/aws-floci-course/configs/course.env
./scripts/setup/floci-up.sh
source ~/aws-floci-course/configs/lab-01.env
source ~/aws-floci-course/configs/lab-02.env
source ~/aws-floci-course/configs/lab-03.env
./scripts/utilities/verify-lab-03.sh
```

**Resource identifiers (also in `configs/lab-03.env`):**

| Resource | ID |
|---|---|
| Key pair | `usms-app-key` |
| Web instance | `i-586eeca96aa9b0754` (`usms-web-01`) |
| DB instance | `i-67a4edf7aa16d42e1` (`usms-db-01`) |
| Web Elastic IP | `eipalloc-15bc32609094705a6` (`54.96.140.123`) |
| Web data volume | `vol-1d8cf780d87149c92` (8 GiB `gp3`, unattached — see Section 7) |
| Golden AMI | none — `create-image` unsupported on this build, see Section 7 |
| Base AMI | `ami-0abcdef1234567891` (Amazon Linux 2023, x86_64) |

**Supplementary files (all in this repository):**
- Bootstrap script: [`labs/lab-03-ec2/user-data.sh`](user-data.sh)
- Request document: [`templates/lab-03-run-instances.json`](../../templates/lab-03-run-instances.json)
- Scripts: [`scripts/utilities/verify-lab-03.sh`](../../scripts/utilities/verify-lab-03.sh),
  [`scripts/cleanup/lab-03-cleanup.sh`](../../scripts/cleanup/lab-03-cleanup.sh)
- Environment config: [`configs/lab-03.env`](../../configs/lab-03.env)
- Review-question answers: [`notes/lab-03-notes.md`](../../notes/lab-03-notes.md)

---

### Submission Checklist

- [x] Aim/Objectives clearly stated
- [x] Introduction provided
- [x] Real-world use case described
- [x] System architecture included
- [x] All implementation steps documented
- [x] CLI output captured as evidence — screenshots are not applicable; see Section 6.1
- [x] Console verification — *N/A for Floci; CLI-substitute table provided*
- [x] Analysis and discussion completed
- [x] Reflection completed
- [x] Conclusion written
- [x] Appendix attached

---

## Problems I hit and how I fixed them

- **Floci had no real state on this machine at all.** The repository was moved to a
  new machine; `configs/lab-01.env`/`lab-02.env` described resources that did not
  exist in this host's fresh Floci instance. Re-ran both labs' resource creation
  against this machine before starting Lab 03, and regenerated `configs/lab-02.env`
  with the new IDs.
- **`jq` was missing**, which silently broke every `verify-lab-02.sh` count-based check
  (NACL entry count, tag-count checks) with no useful error — they just failed.
  Chocolatey's own lock file was stuck from a previous crashed install; downloaded the
  `jq` binary directly instead of fighting the package manager.
- **`chmod 600` on the private key reported success but `stat` still read `644`** on
  this Windows/Git-Bash environment — NTFS ACLs and POSIX mode bits are different
  systems, and `chmod` here only emulates the latter. Applied the actual Windows
  control with `icacls /inheritance:r /grant:r "<user>:(R,W)"` instead, and recorded
  the POSIX-bit check as informational in `verify-lab-03.sh` rather than claiming a
  false pass or a false fail.
- **A JMESPath query of the form `[?filter].Field[0]` silently returned nothing**,
  producing a downstream `ParamValidation: Invalid length for parameter PolicyArn`
  several lines later rather than an error at the point of the actual mistake. The
  filter projects to a list even when it matches one element, and `[0]` needs a pipe
  first: `[?filter].Field | [0]`. Fixed throughout Step 11 once isolated.
- **`describe-addresses --filters "Name=tag:Name,Values=usms-web-eip"` returned every
  Elastic IP, unfiltered** — confirmed by reproducing it in isolation and comparing to
  the raw JSON. Worked around, as Lab 02 did for NACLs and security groups, with an
  unfiltered call plus a client-side `--query` tag match.
- **`attach-volume` and `create-image` both return `UnsupportedOperation`
  unconditionally** on this build, contradicting the course guide's own
  Floci-vs-Real-AWS table. Retried each in isolation, with no other parameter changed,
  to confirm it was not a one-off; recorded as a genuine gap rather than retried
  indefinitely.
- **`describe-instance-attribute --attribute userData` never returns a `UserData`
  field**, confirmed via an unfiltered `--output json` call. Step 12's byte-identity
  proof could not be performed on this build; recorded as such.
- **`python3` would not run** (`command -v` found it, but it is a Windows App
  Execution Alias stub, not the real interpreter) — used `python` instead, which is
  the actual CPython 3.14 install on this machine, for every `-m json.tool` validation.
- **`aws ec2 wait instance-running` hung past its allotted time** on the first launch.
  Interrupted and used the guide's own manual polling loop, which reached `running` in
  about 30 seconds — slower than the guide's "almost instant" claim for Floci, which
  turned out to be explained by this build genuinely pulling and starting a real
  Docker container per instance (see Section 7), not by a stub state machine.
