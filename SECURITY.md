# Security Policy

## Security Model

CarmineAuctionProtocol separates auction state, collateral custody, settlement
accounting and risk-parameter management. Review should focus on preserving bid
ordering, refund accounting, auction finality and collateral distribution across
normal and edge-case auction flows.

## Invariants

- An auction cannot settle before its configured close time.
- Bid amounts must satisfy the configured minimum increment.
- Bid bonds and refunds must reconcile with bidder balances.
- Collateral custody must remain inside the vault until cancellation,
  settlement or a valid claim.
- Settlement must credit the seller exactly once.
- Winner and partial-claim accounting must not distribute more collateral than
  the auction lot holds.
- Governance parameters must remain inside configured bounds.

## Scope

In scope:

- Vyper contracts under `src/`;
- tests under `tests/`;
- scripts under `scripts/`;
- CI and dependency-management configuration.

Out of scope:

- external oracle deployments;
- production ERC20 integrations not included in this repository;
- frontends and dashboards;
- public-network deployments.

## Automated Validation

Run:

```bash
bash scripts/ci.sh
```

The CI flow compiles Vyper sources, regenerates deterministic risk tables,
executes pytest and checks the protocol source-size bounds.

## Reporting

Reports should include:

- observed behavior;
- economic impact;
- affected contracts and functions;
- reproduction steps;
- recommended mitigation;
- regression test expectations.
