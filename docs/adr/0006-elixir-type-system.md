# ADR-0006: Elixir Type System — Native 1.20 Types, No Dialyzer

## Status
Accepted

## Context
Elixir 1.20 introduced a first-class, gradual type system (set-theoretic types). We need a
consistent approach to type annotations across the codebase to catch errors early and
communicate intent, without the operational overhead of Dialyzer.

## Decision
Use the **Elixir 1.20 native type system** exclusively. Dialyzer is **not** used.

### Rules
- The quality gate is `mix compile --warnings-as-errors`. T-category type warnings are
  treated as compile errors and block CI.
- Add `@spec` on **all public and private functions** in domain and boundary modules
  (`Platser.*`, `PlatserWeb.*`).
- Use the most specific types available:
  - Integer range types (e.g. `5..200`) instead of `pos_integer()` when bounds are known.
  - Closed union types for error reasons and enumerated values.
- Use `defguard` / `defguardp` for invariants enforced in function heads.
- **Never add `dialyxir`** to the dependency list.
- **Never run `mix dialyzer`** — it is not part of this project's quality gates.

## Consequences
- **Positive:** Type checking integrated into the standard build step. No separate Dialyzer
  PLT build or CI cache management. Elixir 1.20 type inference catches many errors that
  previously required Dialyzer.
- **Negative:** Elixir's type system is still maturing; some edge cases may not be caught
  that Dialyzer would find. Accepted trade-off for developer experience.
