# Decision workflow: propose before building

Taken over from the Snotra repository on 2026-10-17
([`decision-making.md`](https://github.com/kkrafft1999/snotra/blob/main/.claude/rules/decision-making.md)).

When the user **asks a question** or **describes a problem** ("We need
something like …", "What do you recommend?", "How should we solve X?"):

1. **Don't build it yet.** Look at the matter first — the concept in `docs/`,
   the code once it exists, and the constraints from Snotra's protocol.
2. **Propose several options**, each with a short assessment: what it costs,
   what it buys, how well it fits. A recommendation of your own is welcome,
   marked as a recommendation instead of quietly pre-empting the decision.
3. **Wait for an explicit decision.** Only then is anything written, committed,
   pushed or turned into a pull request.
4. If work already started during the analysis and the user stops before
   deciding: **roll it back** and deliver the options.

## When to act right away

- A **clear instruction to implement** ("Build X", "Fix Y", "Record these
  decisions in the concept").
- **Questions that only ask for information** — a direct answer is enough.
- **Debugging and analysis requests** that explicitly ask for the cause rather
  than for a fix.

Where tasks end up is a separate convention, in
[`task-management.md`](./task-management.md).
