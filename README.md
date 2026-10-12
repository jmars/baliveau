# baliveau

### A flight recorder for agents.

An AI agent runs inside the machine. It rewrites its own configuration, builds new components into the
running store, activates a new **generation** of the system and comes up in it. It can break the
machine — that is a supported outcome, and the machine repairs itself.

What it cannot do is decide what the record says happened.

This is a flight recorder for that agent: a continuous, independent, third-party-readable account of
what the system did, what changed, and who intervened — so that a change can be *reconstructed* and
*reversed* rather than *believed*.

The motivation is twofold and explicit: the **EU AI Act's** observability and record-keeping
obligations, and **European sovereign AI** — infrastructure whose evidence chain belongs to the
operator, not to a vendor.

*The name is the design. In a coppice the underwood is cut on a rotation and regrows from the stool,
while the **baliveaux** are the young trees the woodsman deliberately leaves standing through every
cutting. A baliveau is the reserved generation: the thing you keep while everything around it is taken
and grows back.*

---

## Why the record has to come from outside the agent

Most "self-improving agent" designs rest on the agent being honest about its own results. A flight
recorder cannot work that way: the crew does not write the tape. So the question is inverted here —
**the agent is allowed to try to cheat, and the system is built so the attempt is visible and
reversible.**

- Every state of the system is a **content-addressed generation** in a build store — enumerable,
  comparable, and distinguishable from every other state it has ever been in.
- Every activation, verdict, roll-forward and intervention is recorded by the **substrate**, in plain
  durable files, written by *different writers at different times*.
- The things that judge the work — the oracle that asks *"is it better?"*, the audit that asks *"is it
  honest?"*, the reporter that asks *"is it documented?"* — are **host-side seats**: outside the machine
  the agent controls, unwritable by it, reading state rather than trusting claims.
- **A log the subject can rewrite is not a log.** That is the load-bearing principle: it is why the
  audit compares against its own previous observation, why the boot record is bound to a per-boot token
  only the host can issue, and why the agent's own checkpoint is treated as a self-report and **never as
  evidence**.

### The one place this recorder differs from a real one

A real flight recorder is *hardened*: it survives the crash and cannot be edited. This one is **audited,
not proofed** — and it says so on purpose.

Nothing inside the machine can be *proved* against the agent. The guest kernel offers no sandbox
primitive at all — no LSM, no seccomp, no namespaces — because **the virtual machine is the boundary**,
and the agent is the only thing inside it. So this system does not pretend to make the tape
untamperable. It makes tampering **leave a mark**, and makes the mark **actionable**:

> the tape can be edited — and the edit is detected from outside, and the flight is rolled back.

That is a deliberate design record, not an apology: *auditing, not proofing.* It is also why the
recorder's guarantee is stated as a bound in the tool's own output rather than advertised as a property
it does not have.

---

## The motivations, stated plainly

### 1. The EU AI Act

> *This is an ENGINEERING READING of a legal instrument. It is not legal advice, and nothing here makes
> a system compliant. A provider would need counsel.*

The AI Act's observability-shaped obligations — automatically recording events over the system's
lifetime and retaining them (Art. 12, Art. 19); technical documentation that includes **the changes made
through the lifecycle** (Art. 11 + Annex IV); risk management, post-market monitoring and
serious-incident reporting (Art. 9, 72, 73); human oversight and the ability to intervene (Art. 14);
quality-management records (Art. 17) — reduce, in engineering terms, to one requirement:

> **an attributable, durable, machine-readable record of what the system did, what changed, and who
> intervened.**

That is what this system produces *by construction* — because a system that rewrites itself has to be
able to describe itself, or nobody — including its operator — can tell whether it is still the system
they deployed:

| record | written by | answers |
|---|---|---|
| a generation is a store path, carrying `install` / `provides` / `src_of` / `store` facts and a snapshot version | the activation tool, in the activation transaction | **what** the system was, in every state it has been in |
| a boot log — one line per boot verdict | the init process, per boot | whether each generation actually ran |
| a recovery journal — one row per **automatic** roll-forward | the init process, per recovery | that the machine repaired itself, and from what |
| the runtime datalog | the init process | activations, rollbacks, shutdowns |
| the oracle | the **host** | whether a change was an improvement |
| the audit | the **host** | whether the record itself is intact |
| the config→generation link | the activation tool | **what changed, and from which input** |

Two properties matter more than the list. First, the recovery journal **distinguishes an automatic
roll-forward from a deliberate operator action** — the *"who intervened"* question that most logging
cannot answer. Second, **the judging seats are host-side**, so no amount of tampering inside the machine
reaches the thing that grades the work.

The gaps are tracked in the open rather than assumed closed — see *Status*.

### 2. European sovereign AI

Sovereignty, here, is not a slogan about where the weights are hosted. It is about **who can read the
evidence**. Three concrete properties:

- **The record is the operator's.** It lives in the operator's own store, on their own machine, in plain
  files and a local graph — not in a vendor's telemetry pipeline, and not behind an API.
- **The judgement is the operator's.** The seats that ask *is it better / is it honest / is it
  documented* run **on the operator's own host**. Nothing in the chain of evidence depends on a third
  party's servers, and no external service is asked to attest anything.
- **The system describes itself.** Because the agent's language, configuration and build recipes are
  evaluated *inside* the machine, the deployment carries its own toolchain and its own provenance — so
  an operator can reconstruct a generation's input, and re-derive its state, without the vendor's help.

That is the property a regulated European deployment actually needs: not that the model was trained
here, but that **the account of what the system did is auditable here** — by the operator, and by a
regulator, without asking anyone's permission.

---

## How it works

```
agent (inside the machine)                      substrate (same machine)
  read the system's own state   ──▶  live datalog: generation / install / provides / svc / log
  write a configuration or source ──▶  Dhall is total: it is a value or a type error
  build it IN THE MACHINE        ──▶  a new store path, with its source and its facts
  activate                       ──▶  a new generation, committed and applied to the running root
  the machine comes up in it     ──▶  and if it fails, the machine rolls forward by itself
```

- **A generation is a store path.** The system's states are content-addressed, so they can be compared,
  enumerated and rolled back — and a state that was never active cannot be mistaken for one that was.
- **Activation is a transaction**, not a copy: the configuration is evaluated, the closure computed, the
  generation's facts written, the snapshot published, the running root updated and the new services
  started — and the whole thing is recorded as an effect in the runtime log.
- **Failure is normal.** A generation that fails its boot window is recorded as failed, and the machine
  rolls forward to the last good one — **as a new, higher version**, so the content goes back while the
  version number does not. That behaviour belongs to the substrate, not to the agent.
- **The agent is told not to repeat itself.** A durable record makes the loop refuse to re-issue an
  activation that already failed, and the refusal names its own way out — so a stuck machine is never a
  silent one.
- **The machine's own repairs are counted**, because a *cycle* is invisible one boot at a time: every
  individual boot looks locally correct. Counting the recoveries is what makes an oscillator visible.

---

## The three seats

The system separates **doing** from **judging**, and the judging happens outside the machine.

| seat | question it answers | where it lives | status |
|---|---|---|---|
| the oracle (`osier-share`) | *is it better?* — how much of the running system is written in the project's own language, measured over the components the generation actually runs | host, over the store's own provenance | **built**, and proven to move |
| the audit | *is it honest?* — does the record agree with itself and with what the host observed before? | host, reading records written by different writers at different times | **built**, with its own bound printed in its output |
| the reporter | *is it documented?* — can a third party reconstruct the lifecycle for a regulator? | host, over the substrate's own durable records | **built**, with its taxonomy, retention and bound tables printed on every run |

Each seat is a **frozen seat**: host-side, unwritable by the agent, and a function of observable system
state. A seat that measured the agent's own claims would measure nothing.

---

## Evidence discipline

This repository is written so that its claims can be attacked.

- **Every claim is marked.** MEASURED / INTERPRETATION / PROJECTION — in the code comments, the design
  record and the commit messages alike. The dominant failure mode in this kind of work is not a wrong
  measurement but **an inference wider than the evidence**, so claims are stated at the width their
  evidence allows.
- **A gate is an exit code**, never the tail of stdout.
- **A fix is proved by asymmetry**: the probe must fail before and pass after, and a control must be
  proven to differ from its subject — a pinned reference that happens to equal the working tree proves
  nothing, and a gate that reads a *moving* reference is not a gate.
- **A test that cannot fail is not a test**, so the instruments are mutation-checked: disable the check
  and its fixture must go blind.
- **Corrected claims stay visible.** Refuted claims are marked as refuted rather than quietly reworded,
  because a record that silently rewrites itself is exactly what this project exists to argue against.

---

## Status

**Working, in a virtual machine, and gated.** The agent runs inside a guest, writes its own source and
configuration, **builds them inside the machine** (no host round trip, no image rebuilding), activates
the generation through the init process — which commits and applies it to the running root — and the
following boot comes up in it. The measured end-to-end demonstration: a run-set share that moves
`0.000000 → 0.100376` on a real guest store, with the new component **attributed by the store** rather
than by a host path.

The recorder's guarantees are exercised adversarially, not asserted: an appended forged boot verdict, a
forged line *pair*, a tamper that rewrites every record coherently (caught only in comparison with the
host's previous observation), a boot record bound to a per-boot token the host issues, and an agent's
own checkpoint proven able to vanish without changing a verdict.

**Not built yet, and tracked in the open:**

- the language backend that lets the agent author components in the project's own language — the target
  of the first self-modification task; every other piece is in place and proven without it;
- the **reporter** seat's one remaining input, a *decision* rather than an instrument: a change's
  **intent** (the config each generation was built from is readable now; what was *attempted*, and why,
  is not recorded anywhere). Its **retention policy** is no longer one of these: it is **DECIDED —
  UNBOUNDED (user, 2026-10-12)**, and the seat prints it on every run (the store's files are durable and
  the runtime log is not; nothing is pruned by default, because a rotation reads as a rewrite of a
  previously observed record and would fire on a healthy machine). The **change/incident taxonomy** is
  not among them either — it is frozen in the seat;
- network access as a **typed capability** rather than raw sockets (designed, not implemented);
- a second target: a browser-hosted machine, which needs a purpose-built kernel.

## Repository layout

```
src/                 the agent harness: the loop, its transport, checkpointing, the observation loop
tools/               the agent's tool server; the oracle; the audit seat
tests/               the gates — every claim above is a gate, and each one can fail
docs/                the design record: the decisions, the measurements, the corrections carried
```

The build store, the init process and the build tool are **sibling repositories** in the same
workspace; this harness consumes them rather than vendoring them.

## Running the gates

```sh
make test                    # the resume and observation-loop oracles
make test-audit              # the audit seat: coherence, tampering, the trigger
make test-osier-share        # the oracle: does the measurement discriminate?
make test-agent-slot-inguest # the whole loop, inside a guest: written, built, activated, run
sh tests/qemu-agent-observe.sh   # two arms in one run: the loop with and without its guardrail
```

Most gates need a pinned kernel and a package toolchain; they skip loudly when a prerequisite is absent
rather than passing quietly. Several take minutes, because they boot real machines.
