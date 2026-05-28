# ADR-0008: Code Generation Strategy — Igniter-Backed Tasks

## Status
Accepted

## Context
Manual file scaffolding for Ash resources, domains, authentication, and authorization is
error-prone and verbose. Igniter provides a composable, idempotent code-generation system
that integrates with Ash generators.

## Decision
**Prefer Igniter-backed tasks** over manual file edits or plain Phoenix generators for all
scaffolding work.

### Preferred generators
| Task | Command |
|------|---------|
| Add + configure a dependency | `mix igniter.install <package>` |
| New Ash resource | `mix ash.gen.resource Domain.Resource` |
| New Ash domain | `mix ash.gen.domain MyApp.MyDomain` |
| Authentication setup | `mix ash_authentication.install` |
| Authorization (AshPolicyAuthorizer) | via `mix igniter.install ash` flags |

### When to fall back to direct file editing
Only fall back when **no Igniter-backed task exists** for the required change. In that case,
document the manual step in a comment or the relevant ADR.

## Consequences
- **Positive:** Generated code follows framework conventions. Igniter tasks are idempotent —
  safe to re-run. Reduces boilerplate errors.
- **Negative:** Must check whether a generator exists before hand-coding. Some niche
  configuration still requires direct file edits.
