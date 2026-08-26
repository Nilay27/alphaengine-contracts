# Contract compatibility and consumer policy

Load this policy for ABI, event, getter, error, permission, manifest, listener,
or consumer changes.

## Canonical semantics

1. This repository is authoritative for contract ABI, events, storage, getters,
   and permission semantics.
2. State, events, and getters are deterministic and order-stable for identical
   inputs. Listener-critical events reflect stored state exactly.
3. Consumer repositories map explicit contract surfaces; they must not infer
   undocumented behavior.
4. Contract/event specifications in `docs/**` and `src/**` outrank chat memory.

## Change requirements

1. Any external ABI, event, storage, or permission change requires synchronized
   Solidity tests and documentation.
2. Any listener-facing event change is a compatibility change for
   `listener-service` and requires consumer impact documentation/tests.
3. Prefer additive changes. Breaking changes require versioning, migration
   notes, and explicit consumer coordination.
4. Deployment manifests and generated ABIs must be updated without overwriting
   historical evidence unless the migration plan explicitly permits it.
5. Every state-changing external function requires event assertions; test
   stored-state/event/getter parity.

## Failure and dependency boundaries

1. Use explicit custom errors for repository-owned failures.
2. Consumers map error selectors/codes explicitly, never by parsing revert text.
3. Compatibility shims record owner, removal trigger, and removal date/phase.
4. Refresh pinned/local dependencies before validation; stale dependency state
   is a compatibility failure, not flaky tooling.
5. Update `docs/development-log.md` whenever behavior, storage, ABI, event,
   permission, or dependency boundaries change.
