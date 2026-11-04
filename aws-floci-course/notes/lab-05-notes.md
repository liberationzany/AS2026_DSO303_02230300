# Lab 05 notes

## Step 3 support path

**Path A — full.** `describe-load-balancers`, both `--generate-cli-skeleton` calls,
`describe-listeners` (correctly rejecting a non-ARN with a validation-shaped error),
`describe-account-limits`, and the ECS integration calls all answered. This build
turned out to go well beyond "control plane only": the target group's health checks
are genuinely evaluated against the real nginx containers Lab 04 discovered this
build runs, and both targets reached `healthy` — see Section 7 of the report.

## Source material note

The provided PDF guide for this lab is genuinely truncated at the source — it ends
mid-command on page 76 of 77, inside Step 11, with the rest of Step 11, Section 9's
verify/cleanup scripts, Troubleshooting, the Floci-vs-Real-AWS table, the exercises,
the review questions, and the appendices never extracted (confirmed by opening the
PDF directly: page 77 of 77 contains only a footer). The build below (Steps 1–13 and
the env file/verification/cleanup) follows the guide faithfully everywhere it exists,
and the review questions below are written to the same standard as Labs 01–04's,
answering what the available Learning Objectives and interludes establish as the
lab's central ideas, since the guide's own Section 15 was not recoverable.

## Review questions

**1. (4.3) "Say that out loud before you continue" — the load-balancer-as-general-case sentence.**

Lab 04 Step 9's security group rule, sourced from `usms-app-sg` rather than a CIDR
block, was a narrow fix for a narrow problem: the enrolment tasks have no stable
address, so a firewall rule written against one is wrong the moment it is typed. A
load balancer is the general form of that same realization, applied to every other
thing that might need to find the tasks — not just the firewall, but every client,
every config file, every monitoring probe, every DNS record. Watching the ECS
service register and deregister targets in the target group (Step 11) is the same
behavior Lab 04's security-group-reference already relied on, one layer up: something
else keeps the list of real addresses current, so that nothing upstream of it ever
has to know or care what those addresses currently are.

**2. Why does a target group serving Fargate tasks require `--target-type ip`, and what actually happens if you choose `instance`?**

A Fargate task launched in `awsvpc` mode has no EC2 instance underneath it — there is
no instance ID for `instance`-type registration to reference. `ip` is the type that
identifies a target by address and port instead, which is what an `awsvpc` task's
elastic network interface actually has. Choosing `instance` does not fail where you'd
expect: `create-target-group --target-type instance` succeeds immediately, because
the API has no way yet to know what will try to register into it. The error surfaces
much later, at the `update-service`/`create-service` attachment step, with a message
about the network mode rather than about the target type — a slow failure for what
is, in hindsight, a decision made correctly or incorrectly several steps earlier.

**3. Container health check vs. target group health check: how can a task be `HEALTHY` and `unhealthy` at the same time, and what does that combination mean?**

The container health check (Lab 04) runs *inside* the task, as a command the
container runtime executes, and reports whether the process is alive and answering
itself. The target group health check (this lab) runs *outside* the task, as an HTTP
request the load balancer sends across the network, and reports whether the process
is reachable through the security group and the routing path. A task that is
`HEALTHY` to ECS but `unhealthy` to the target group means exactly one thing: the
application itself is fine, and the network path to it is not — in this lab's case,
specifically, that Step 9's security-group rule admitting `usms-alb-sg` is missing or
wrong. Reading those two fields together, rather than either alone, is what turns
"something is broken" into "I know which half is broken" in under a minute.

**4. Why is the direct-access rule removed at the end (Step 13) rather than the start, and what would go wrong if the order were reversed?**

Step 9 adds the load balancer's access *while the web tier still has its own*, Step
12 proves the new path works, and only then does Step 13 remove the old one. Doing it
in that order means there is a continuous window in which both paths are valid, so
cutting over is a verified swap rather than a gamble. Reversing the order — removing
the direct rule before the new path is proven — would mean that if anything about the
load balancer, the target group, or the new security-group rule were wrong, the
enrolment service would become completely unreachable with no fallback and no
warning, for however long it took someone to notice and re-authorize the old rule.
The difference between "migration" and "outage" in this lab is entirely in which of
two already-written steps runs first.

**5. The load balancer's DNS name and an Elastic IP (Lab 03) are both "stable addresses that survive instance churn." What's actually different between them?**

An Elastic IP is a single address that one instance holds at a time; moving it means
re-associating it with a different instance. A load balancer's DNS name resolves to
*multiple* addresses — one node per Availability Zone — and the load balancer itself
decides, request by request, which of potentially many healthy *targets* (not just
one instance) receives traffic, based on a health check it runs continuously. An
Elastic IP gives you address stability for a single compute resource; a load balancer
gives you address stability for a pool of them, with its own opinion about which
members of that pool are currently fit to receive anything. The enrolment service's
tasks could never have used an Elastic IP in the first place — Lab 03's EIP attaches
to one EC2 instance, and there is no equivalent "attach to a Fargate task" operation at
all, which is itself a clue that a load balancer isn't an upgrade from an Elastic IP;
it's solving a problem Elastic IPs were never shaped to solve.
