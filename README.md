# Lastlight: a dead-man's switch that runs itself

If you hold crypto alone, it dies with you. Lastlight is an inheritance vault that needs **no keeper bot, no
server and no trusted executor**: you check in now and then; if you go silent past your deadline, Reactive Network
notices on its own and releases the vault to your heirs.

Built for the Reactive Omni Buildathon, track **Set It and Forget It**.

## How it works

```
 Ethereum Sepolia                                   Reactive Network (Lasna)
 ────────────────                                   ────────────────────────
 LastlightFactory.create()  ── VaultCreated ──────▶ LastlightReactive
 LastlightVault                                       • subscribes to the new vault's CheckIn / Released
   checkIn() / withdraw() / setPlan()  ── CheckIn ──▶   • keeps each vault's deadline in its own state
                                                      • Cron100 tick: walks the vaults round-robin
   warn(rvm)    ◀──────── callback ─────────────────    - in the warning window  → warn()
   release(rvm) ◀──────── callback ─────────────────    - past the deadline      → release()
        │                                               - no Released seen after 30 min → retry (max 5)
        └── Released ─────────────────────────────▶  • stops guarding, unsubscribes
```

- **Proof of life is any owner action**: `checkIn()`, `withdraw()`, `withdrawToken()`, `setPlan()`.
- **The vault trusts its own clock, not the callback.** `release()` re-checks `block.timestamp >= deadline` on
  Sepolia, so an early, delayed or replayed callback can never release funds; a stale `warn()` after a check-in is
  ignored. Callbacks are accepted only from the Reactive callback proxy *and* only when they come from the
  reactive contract the vault was built for (`onlyServiceProvider` + `onlyCallbackSender`).
- **Heirs**: up to 5, split in basis points; ETH plus up to 5 listed ERC-20s. ETH is pushed with a gas cap; an heir
  that refuses ETH is credited and can `claim()` later, so one bad heir can't block the others.
- **Callback gas is paid by the vault**: it keeps `gasReserve` back on release to settle the callback proxy.
- **One reactive contract guards every vault** the factory makes. New vaults are picked up from `VaultCreated`
  with dynamic subscriptions: nobody registers anything by hand. Cron work is bounded (`maxPerTick`, round-robin
  cursor), and the operator can `pause()` the cron subscription to stop billing.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `src/LastlightVault.sol` | Sepolia | the vault (`AbstractCallback`) |
| `src/LastlightFactory.sol` | Sepolia | deploys vaults, emits `VaultCreated` |
| `src/LastlightReactive.sol` | Lasna | watches events, runs the cron, sends callbacks (`AbstractReactive`, reactive-lib-omni) |

Deployed addresses and the full-loop transaction hashes are listed under **Live run** below.

## Tests

```
forge test
```
14 tests cover the full loop (create → guard → warn → release → stop), a check-in after the warning, every owner
action counting as proof of life, early release rejected by the vault's own clock, retry after a failed callback,
forged callbacks and non-system `react()` rejected, strangers can't check in, pause stops the cron, many vaults
round-robin, an heir that refuses ETH can still claim, and bad plans rejected. The test harness mocks the Reactive
system contract (`test/Harness.sol`), because the published test library targets the older API.

Dependencies (in `../lib`): `reactive-lib-omni`, `forge-std`. Solidity 0.8.30.

## Deploy

```
export PRIVATE_KEY=0x...   LASNA_RPC=https://lasna-rpc.rnk.dev/   SEPOLIA_RPC=<sepolia rpc>
forge script script/Deploy.s.sol:DeployReactive --rpc-url $LASNA_RPC --broadcast            # prints REACTIVE
REACTIVE=0x.. forge script script/Deploy.s.sol:DeployFactory --rpc-url $SEPOLIA_RPC --broadcast   # prints FACTORY
REACTIVE=0x.. FACTORY=0x.. forge script script/Deploy.s.sol:WireFactory --rpc-url $LASNA_RPC --broadcast
FACTORY=0x.. HEIR=0x.. forge script script/Deploy.s.sol:DemoVault --rpc-url $SEPOLIA_RPC --broadcast
```
The demo vault has a 30-minute heartbeat with a warning 15 minutes before the deadline, so the whole loop can be
watched in under an hour.

## Live run

*Pending: addresses and tx hashes for create → CheckIn → warn → release → Released go here.*

## Limits

- Lastlight is a demo on testnets; it has not been audited. Don't put real savings in it.
- Release timing is "deadline + up to one cron interval", not to the second.
- If the vault can't pay for its callbacks (balance below the debt), release waits until someone sends ETH and
  calls `coverDebt()`; the reactive side retries up to 5 times.

MIT licensed. By Tessel Works.
