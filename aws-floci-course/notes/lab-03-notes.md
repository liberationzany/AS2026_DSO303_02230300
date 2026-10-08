# Lab 03 notes

## The connecting idea (Step 11)

`USMSStudentDataReadWrite` grants `usms-ec2-app-role` access to a bucket,
`usms-student-data`, that does not exist until Lab 04. This is valid, not broken:
an IAM policy is a statement about an ARN, not a reference to a live object, so it
is perfectly legal to grant access to a resource nothing has created yet. Today the
grant simply has no effect — there is nothing at that ARN for it to apply to. The
moment Lab 04 runs `create-bucket` for `usms-student-data`, nothing about the policy
changes, but the ARN it already named starts resolving to a real object, and
`usms-web-01` gains the ability to read and write it with no access key anywhere on
the instance. This is the single most important connection between Labs 01, 03 and
04 in the course so far.

## Review questions

**1. Step 8 launched an instance using a subnet (Lab 02), a security group (Lab 02),
an instance profile (Lab 01), and a key pair and script (Lab 03). What would have
happened had each been wrong or missing, and which failures are immediate vs.
silent?**

- Wrong/missing **subnet** → immediate, loud failure: `InvalidSubnetID.NotFound`.
  `run-instances` never returns an instance ID.
- Wrong/missing **security group** → immediate, loud failure: `InvalidGroup.NotFound`.
  Same category as the subnet.
- Wrong/missing **instance profile** → immediate, loud failure:
  `InvalidParameterValue: iamInstanceProfile.name`. The instance never launches.
- Wrong/missing **key pair** → immediate, loud failure: `InvalidKeyPair.NotFound`.
- Wrong/missing **user-data script** → **silent**. `run-instances` does not validate
  user data beyond the 16 KB size limit and accepts an empty, malformed, or
  irrelevant script without complaint. The instance launches, reaches `running`,
  and looks identical to a correctly-bootstrapped one in every field
  `describe-instances` returns. The failure only becomes visible later, and only if
  someone checks for it — exactly why Step 12's byte-for-byte proof exists, and why,
  on this Floci build, that proof could not actually be completed (the API has no
  readable `UserData` field at all here — see Section 7 of the report).

The pattern: anything AWS has to resolve a real resource ID or ARN for fails loudly
and immediately. Anything that is just an opaque payload (user data) is accepted
unconditionally and fails, if at all, silently and later.

**2. Why is `USMSStudentDataReadWrite` naming a bucket that doesn't exist valid
rather than broken, and what changes when Lab 04 creates it?**

Answered above under "The connecting idea." In one additional sentence: IAM policy
evaluation is independent of resource existence — a `Deny` or `Allow` statement is
checked against an ARN string at call time, not against a catalogue of resources
that exist right now, so writing the permission early and creating the resource
later is not just tolerated but is the normal order of operations in a system built
by more than one team.

**3. Why doesn't putting application deployment in user data make "restarting the
instance redeploys it" true, and what are two approaches that do work?**

User data is read and executed exactly once, at the instance's first boot — not on
every boot and not on every restart. Stopping and starting an instance, or
rebooting it, does not re-run cloud-init's user-data stage; the instance's
first-boot flag is already set. Two approaches that do redeploy on every restart:
(1) move the deployment logic out of user data and into a `systemd` unit or
cloud-init `bootcmd`/`runcmd`-equivalent that is configured to run on every boot,
not just the first; or (2) do not deploy by booting at all — bake the configured
state into a golden AMI (Step 20's intent) and replace the instance rather than
restart it, so "redeploy" means "launch a new instance from a new image," which is
also the pattern a real Auto Scaling group (Lab 08) uses.

**4. Compare the auto-assigned public address with the Elastic IP across who owns
it, when it changes, what it costs, and what happens on stop — then describe a
failover procedure only possible because of the difference.**

| | Auto-assigned public IPv4 | Elastic IP |
|---|---|---|
| Owner | AWS, on loan to the instance | The AWS account, until explicitly released |
| Changes | Every stop/start cycle | Never, until you release it |
| Cost | Free | Free while associated with a running instance; billed hourly while allocated and unassociated |
| On stop | Released immediately | Stays allocated; detaches from the instance's "current address" but the association record persists |

Because an Elastic IP is a resource with its own lifecycle, independent of any one
instance, you can **re-associate it with a different, already-running instance** in
seconds: if `usms-web-01` fails, launch or promote a standby instance and call
`associate-address` to move `usms-web-eip` onto it. The address a client or DNS
record points at never has to change — only which instance answers behind it. This
is the entire mechanism of a cold-standby failover, and it is only possible because
the address and the instance are decoupled.

**5. An EBS volume can't cross Availability Zones, but a snapshot of it can be
restored into any AZ in the region. What does that imply about where each is
stored, and what does it mean for surviving the loss of one AZ?**

A volume lives in exactly one AZ's storage fabric — the physical disks backing it
are in that AZ, full stop, which is why `attach-volume` to an instance in a
different AZ fails outright rather than being slow. A snapshot, by contrast, is
stored in S3, which is itself replicated across multiple AZs in the region. Taking
a snapshot is therefore the one operation that moves data out of a single AZ's
blast radius. The implication for a system that must survive losing an AZ: durable
state cannot rely on "the volume is still there" if that volume's AZ is the one
that went away — it must rely on something already copied out of that AZ, whether
that is a recent snapshot, cross-AZ replication at the application layer (e.g. a
multi-AZ RDS instance, Lab 06), or an object store that was always regional. A
single EBS volume, no matter how carefully tagged and attached, is a single-AZ
dependency by construction.

**6. Step 14 verified six configuration properties instead of confirming the
application answered. Is that an adequate substitute, and what fault class can it
not detect?**

It is an adequate substitute for everything it actually tests: it proves the
network path, the firewall, and the addressing are all configured to *permit* the
request to succeed, which is the complete and correct diagnosis for "why can't I
reach it" when the real cause is infrastructure misconfiguration — and on real AWS
that is the large majority of such cases. It cannot detect the one fault class
entirely inside the instance itself: a crashed or never-started application
process, a bug in the application, or a service listening on the wrong port. Six
`describe-*` calls against AWS's control plane have no visibility into what a
process on the instance's own loopback interface is doing. The seventh link — "is
something listening on port 80" — has to be checked a different way (a status
check, a log, or, if you have access, actually logging in), and Floci's inability
to boot a real OS for this instance is exactly what makes that seventh link
unverifiable here specifically, not a weakness of the six-link method itself.

**7. `usms-web-01` and `usms-db-01` are both `t3.micro` launched from the same AMI.
List every difference and classify each as a property of the instance, the subnet,
or the VPC.**

| Difference | Property of |
|---|---|
| Subnet ID (`usms-public-subnet-a` vs. `usms-private-subnet-a`) | the **instance's placement**, chosen at launch |
| Whether the subnet auto-assigns a public IPv4 (`MapPublicIpOnLaunch`) | the **subnet** |
| Security group (`usms-app-sg` vs. `usms-db-sg`) | the **instance** (attached at launch, could be changed later) |
| Whether an IAM instance profile is attached | the **instance** |
| Whether the route table reaches an Internet Gateway or only a NAT gateway | the **subnet** (via its route table association) |
| The VPC CIDR, DNS settings, and the Internet Gateway's existence | the **VPC** — identical for both, since they share one VPC |
| Instance type, AMI, key pair | the **instance** — identical for both by construction in this lab |

The exercise is really asking whether the reader can tell these three scopes apart:
a VPC-level property is shared by everything inside it; a subnet-level property is
shared by everything in that one subnet; an instance-level property can differ
between two instances in the very same subnet. `usms-web-01` and `usms-db-01` differ
at every level *except* the VPC, which is exactly what a correct two-tier design
inside one VPC should look like.
