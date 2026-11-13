# Spike: demand-driven ephemeral runners on the mac-mini

Status: plan, not started. Written 11 Nov 2026.

## Problem

Four persistent runners (BidProof, ScoreView, two TenantSafe) idle inside one 6 GiB Colima VM on a 16 GB Mac.

- Runners are registered per repository, so idle runners cannot take another repository's work. On 11 Nov five BidProof jobs queued behind one BidProof runner while three others sat idle.
- The VM keeps memory its guest has freed until it restarts (Apple's container docs: macOS Virtualization only partly supports ballooning; Colima's docs are silent on it).
- Adding a second persistent runner for BidProof would only put more jobs into the same memory.

## Proposal

One service on the mini that creates a runner when a job is waiting, lets it run exactly one job, and removes it. Capacity is a memory budget, not a count of runners.

- **Orchestrator:** a small Go service using GitHub's Runner Scale Set Client (github.com/actions/scaleset, Public Preview). It long-polls GitHub, so nothing needs to reach the Mac from outside. For each waiting job it requests a JIT runner config and starts an ephemeral runner.
- **Runner host:** one Colima VM sized to the budget, running each runner as a short-lived container. The VM is stopped when idle, which returns all its memory to macOS, and started ahead of expected demand (below). `colima start` on the mini took about 28 seconds (it printed `INFO[0028] done` on 11 Nov).
- **Concurrency cap:** the orchestrator sends a maximum capacity with each poll. It sets that from the memory budget, so excess jobs wait in GitHub's queue instead of in swap.
- **Two hosts:** the M1 iMac joins the pool (Hangar's card shows it as 8 GB; the mini is 16 GB). Each host has its own memory budget and its own on-demand VM, and the orchestrator picks where a runner starts.
  - Prefer a host whose VM is already up with room under its budget, so a second VM is booted only when the first is full. That keeps one VM running in quiet periods instead of two.
  - The cap sent to GitHub is the sum of the hosts' budgets. A host under memory pressure (the same sysctl reading Hangar already uses) gets no new runners until it recovers.
  - The orchestrator runs on the mini and starts runners on the iMac over SSH with key authentication, the way Hangar already reaches its hosts. No second service to keep alive.
  - The prediction warms the primary host first and the iMac only when forecast demand exceeds the primary's budget. Both are arm64, so a job runs on either.

## Prediction: keep the VM up only when work is likely

The aim is to avoid booting for every job and avoid holding a VM for nothing. Signals, cheapest first:

1. **Hour-of-week demand profile.** Hangar's `UtilisationLog` already records, per hour, each runner's busy and total polls, the peak queue and the longest wait (`Sources/Hangar/Services/UtilisationLog.swift`). A runner maps to one repository, so this gives demand per repository per hour. Limit: it keeps only 8 days, which is one sample per hour-of-week. The orchestrator should keep its own longer log (counts only, as Hangar does) from day one.
2. **Scheduled workflows.** Cron triggers in the workflows are known in advance (for example the BidProof nightly Playwright run). Warm the VM a few minutes before each.
3. **Live activity.** A recent push or open pull request on a repository raises the chance of a job in the next few minutes. This needs GitHub API reads beyond what Hangar polls today.
4. **Idle timeout.** Stop the VM after N idle minutes (start with 15). Tune N from the log: the cost of a wrongly stopped VM is about 28 seconds of start time.

Phase 1 uses signals 1, 2 and 4 only. Signal 3 is added only if the first results show cold starts hurting.

## Contract (what the spike must show)

| # | Deliverable | Pass check |
|---|---|---|
| 1 | Service creates a JIT ephemeral runner for BidProof when a job is queued and starts it | A queued BidProof job on a test branch starts on the new runner within 60 s of the VM being up; `gh api repos/rsutcliffe/BidProof/actions/runners` shows the runner while it runs and not after |
| 2 | One job per runner, runner removed afterwards | After a job, the runner is gone from GitHub and its container is gone from the VM |
| 3 | Memory cap respected | Three BidProof jobs queued with a cap of two: two run, one waits; the mini shows no pressure above normal and swap used stays under 2 GB (`memory_pressure`, `sysctl vm.swapusage`) |
| 4 | VM stops when idle and memory returns | After the idle timeout, `colima list` shows it stopped and the mini's free memory rises by about the VM's size |
| 5 | Warm start from schedule | The VM is up before the next scheduled workflow and the job starts without waiting for a boot |
| 6 | Load spread across both hosts | With the mini's budget full, an extra queued job starts on the iMac and the iMac's VM boots only then; when the queue empties both VMs stop. Neither host's swap used rises above 2 GB while three or more jobs run |
| 7 | Comparison with today | A week of side-by-side numbers: queue wait per job, peak memory, hours the VM was up, against the persistent runner over the same week |

The existing persistent runner stays in place and registered the whole time. The spike never takes BidProof's current runner away.

## Verify first (unknown from the docs I read)

- How the encoded JIT config is passed to the runner application at startup. The REST page does not say.
- How a workflow targets a scale set (a label versus the scale-set name), and whether multiple labels work on github.com. The scaleset README says multiple labels need a GHES feature flag on 3.18 to 3.20, and says nothing about github.com.
- Whether repository-level scale sets work for repositories owned by a personal account. The README says repository scope is supported. Not tried.
- Whether BidProof's jobs need Docker inside the job (service containers, Supabase). Check its workflow files. If so, the runner containers need Docker access to the VM's daemon.
- The mini's macOS version, if Apple's `container` is ever considered as a per-job VM (it needs macOS 26 for full container networking).
- The iMac's setup: whether its runner is native or inside Colima, whether Colima is installed, its macOS version, and how much memory a VM can have there. Its card shows 8 GB, so the budget is smaller than the mini's. Check with `sysctl hw.memsize` and `colima list` on it.
- Whether the iMac's existing `imac-tenantsafe-ci` runner can stay put during the spike. It is TenantShield's only runner there, so leave it alone.

## Credentials (see ~/.claude/CLAUDE.md section 0.55)

JIT config generation needs a token with admin on the repository (`repo` scope for a classic token) or a GitHub App. Hangar's existing token is for reading and should not be reused for this.

| Field | Value |
|---|---|
| Purpose | Let the orchestrator register one-job runners |
| Why not a constant | It is a secret |
| Consumer | The orchestrator service on the mini only |
| If unset | Service does not start; the persistent runner keeps working |
| Blast radius | Can register runners, which can run code, on BidProof |
| Preference | A GitHub App scoped to BidProof only, over a personal token |
| Removal | With the service, if the spike is abandoned |

A decision for the owner: App or personal access token. Everything else can be built around either.

## Changes outside this repository (hand over, do not edit from here)

- BidProof workflows: change how they target runners if the scale set needs it. That is the BidProof session's work, with the spec from this document and the verification above.
- ScoreView and TenantSafe: out of scope for the spike. Their runners stay persistent.

## Out of scope

Actions Runner Controller and Kubernetes; Apple's `container`; moving the other three repositories; changing Hangar. After the spike, Hangar would need to show ephemeral runners as they come and go, but that waits for the result.

## Build order

1. Resolve the "verify first" list by reading docs and running the scaleset example against a throwaway repository, not BidProof.
2. Orchestrator on the mini only, with a fixed cap and always-on VM: contracts 1, 2, 3.
3. Idle stop and memory return: contract 4.
4. Add the iMac as a second host with placement by free budget: contract 6.
5. Hour-of-week and schedule warm-up: contract 5.
6. One week alongside the persistent runner: contract 7, then decide whether to roll out to the other repositories.
