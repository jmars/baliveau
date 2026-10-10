# baliveau

**An auditable, self-modifying agent system — built so that a third party can reconstruct what it
did, what changed, and who intervened.**

A *baliveau* is the young tree a woodsman deliberately leaves standing through every cutting, so it
grows into a full standard while the wood around it is taken and comes back. The name is the design:
the system keeps a **reserved generation** while everything around it is rewritten.

An agent runs *inside* the machine. It rewrites its own configuration, builds new components into the
running store, activates a new **generation** of the system and comes up in it. It can break the
machine — that is a supported outcome, and the machine repairs itself. What it cannot do is decide what
the record says happened: **provenance and rollback come from the substrate, not from the agent, and
not from a promise the agent makes.**

---

## Why this is an *auditable* agent system, and not merely a self-modifying one

Most "self-improving agent" designs rely on the agent being honest about its own results. Here the
question is turned around: **the agent is allowed to try to cheat, and the system is built so that the
attempt is visible and reversible.**

- Every state of the system is a **content-addressed generation** in a build store — enumerable,
  comparable, and distinguishable from every other.
- Every activation, verdict, roll-forward and intervention is recorded by the **substrate**, in plain
  durable files, written by different writers at different times.
- The things that judge the work — the oracle that asks *"is it better?"*, the audit that asks *"is it
  honest?"*, the reporter that asks *"is it documented?"* — are **host-side seats**. They live outside
  the machine the agent controls, they are unwritable by the agent, and they read state rather than
  trusting claims.
- **A log the subject can rewrite is not a log.** That principle does the work here: it is why the
  audit compares against its own previous observation, why the boot record is bound to a per-boot token
  only the host can issue, and why the agent's own checkpoint file is treated as a self-report and
  **never as evidence**.

This stance is deliberate and is recorded as a decision, not inferred from the code: *auditing, not
proofing.* Nothing inside the guest can be *proved* against the agent — the guest kernel has no
sandbox primitive at all (no LSM, no seccomp, no namespaces), and the VM is the boundary. So the system
does not pretend to prevent cheating. It makes cheating **leave a mark**, and it makes the mark
**actionable**: roll back.

---

## The AI Act angle

> *This section is an ENGINEERING READING of a legal instrument. It is not legal advice, and nothing
> here makes a system compliant. A provider would need counsel.*

The EU AI Act's observability-shaped obligations — automatically recording events over the system's
lifetime and retaining them (Art. 12, Art. 19); technical documentation that includes **the changes
made through the lifecycle** (Art. 11 + Annex IV); risk management, post-market monitoring and
serious-incident reporting (Art. 9, 72, 73); human oversight and the ability to intervene (Art. 14);
quality-management records (Art. 17) — reduce, in engineering terms, to one requirement:

> **an attributable, durable, machine-readable record of what the system did, what changed, and who
> intervened.**

That is what this system produces *by construction*, because it was built to be self-modifying and
therefore had to be able to describe itself:

| record | written by | answers |
|---|---|---|
| a generation is a store path, with `install` / `provides` / `src_of` / `store` facts and a snapshot version | the activation tool, in the activation transaction | **what** the system was, in every state it has been in |
| `.bootlog` — one line per boot verdict | the init process, per boot | whether each generation actually ran |
| `.recovery` — one row per **automatic** roll-forward | the init process, per recovery | that the machine repaired itself, and from what |
| the runtime datalog (`rt_effect`, `rt_control`) | the init process | activations, rollbacks, shutdowns |
| the oracle | the **host** | whether a change was an improvement |
| the audit | the **host** | whether the record itself is intact |
| the config→generation link | the activation tool | **what changed, and from which input** |

Two properties matter more than the list. First, **`recovery` distinguishes an automatic roll-forward
from a deliberate operator action** — the "who intervened" question that most logging cannot answer.
Second, **the judging seats are host-side**: no amount of tampering inside the machine reaches the
thing that grades the work.

The gaps are tracked in the open rather than assumed closed — see *Status* below.

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
  version number does not. That behaviour is the substrate's, not the agent's.
- **The agent is told not to repeat itself.** A durable record makes the loop refuse to re-issue an
  activation that already failed, and the refusal names its own way out, so a stuck machine is never a
  silent one.
- **The machine's own recovery is counted.** A journal of automatic roll-forwards makes a *cycle*
  visible, because every individual boot looks locally correct.

---

## The three seats

The system separates **doing** from **judging**, and the judging is done from outside the machine.

| seat | question it answers | where it lives | status |
|---|---|---|---|
| `osier-share` | *is it better?* — how much of the running system is written in the project's own language, measured over the components the generation actually runs | host, over the store's own provenance | **built**, and proven to move |
| `fx-audit` | *is it honest?* — does the record agree with itself and with what the host observed before? | host, reading records written by different writers at different times | **built**, with its own bound stated in its output |
| the reporter | *is it documented?* — can a third party reconstruct the lifecycle for a regulator? | host (designed) | **not built** |

Each seat is a **frozen seat**: host-side, unwritable by the agent, and a function of observable system
state. A seat that measures the agent's own claims would measure nothing.

---

## Evidence discipline

This repository is written so that its claims can be attacked.

- **Every claim is marked.** MEASURED / INTERPRETATION / PROJECTION, in the code comments, the design
  record and the commit messages alike. The dominant failure mode in systems work is not a wrong
  measurement — it is **an inference wider than the evidence**, so claims are stated at the width the
  evidence allows.
- **A gate is an exit code**, never the tail of stdout.
- **A fix is proved by asymmetry**: a regression probe must fail before and pass after, and a control
  must be proven to differ from its subject — a pinned reference that happens to equal the working tree
  proves nothing, and a gate that reads a *moving* reference is not a gate.
- **A test that cannot fail is not a test**, so instruments are mutation-checked: disable the check and
  the fixture must go blind.
- **Corrected claims stay visible.** Refuted claims are marked as refuted rather than quietly reworded,
  because a record that silently rewrites itself is exactly what this project exists to argue against.

The design record, `docs/baliveau-self-plan.md`, also carries a section of corrections — including
claims of the author's own that measurement refuted — because the point of the exercise is the
evidence, not the narrative.

---

## Status

**Working, in a virtual machine, and gated.** The agent runs inside a guest, writes its own source and
configuration, **builds them inside the machine** (no host round trip, no image rebuilding), activates
the generation through the init process — which commits and applies it to the running root — and the
following boot comes up in it. The measured end-to-end demonstration: a run-set share that moves
`0.000000 → 0.100376` on a real guest store, with the new component **attributed by the store** rather
than by a host path.

The guarantees are exercised adversarially: an appended forged boot verdict, a forged line *pair*, a
tamper that rewrites every record coherently (caught only by comparison with the host's previous
observation), a boot record bound to a per-boot token the host issues, and an agent's own checkpoint
proven to be able to vanish without changing a verdict.

**Not built yet, and tracked in the open:**

- the language backend that lets the agent author components in the project's own language (the target
  of the first self-modification task — every other piece is in place and proven without it);
- the **reporter** seat, and two of the three records it needs: a **change/incident taxonomy**, and a
  **retention policy** (the store's files are durable; the runtime log is not — that difference is
  currently unequal and stated rather than assumed);
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

Most gates need a pinned kernel and a package toolchain; they skip loudly when a prerequisite is
absent rather than passing quietly. Several take minutes, because they boot real machines.
