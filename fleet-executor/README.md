# fleet-executor — LANE 5 (BUILD WAVE 1)

The merged **EIP-7702 delegate**: one installed delegate drives every fleet surface, authorised by an
off-chain EIP-712 signature. Unions `g3a-sponsorship/SponsorTarget` + `p3c-7702/P3cDelegate` and
generalises them from "forward one call" to "run a signed BATCH of `(target,value,data)`".

**Self-contained. Non-custodial, non-upgradeable, no `selfdestruct`, `nonReentrant` on every value
path. Nothing deployed.**

## The fix (audit #2 + #3, generalised)

Sibling forwards had no auth: inside a delegate `msg.sender` is the CALLER (a relayer), never the user,
so anyone could call the delegated EOA and make it run caller-chosen code in the user's frame. "Self
calls only" breaks the relay (`from=relay,to=user` ⇒ `msg.sender != address(this)`). So the fix is an
EIP-712 intent over the WHOLE batch:

- `execute(Call[] calls, uint256 nonce, uint256 deadline, bytes sig)` — user signs off-chain, any
  relayer carries; `ecrecover(digest) == address(this)` (== the delegating EOA) binds it.
- `Call{address target; uint256 value; bytes data}` — the array is hashed per EIP-712 (encodeType with
  the referenced `Call` type), so every target, value and calldata is SIGNED, not caller-chosen.
- `executeSelf(Call[])` — `msg.sender == address(this)`, no signature needed.
- `execute(bytes32 mode, bytes data)` — ERC-7821 compat (mode 0x00 single, 0x01 batch), **GATED**:
  self OR a valid intent (see `execute(bytes32,bytes,nonce,deadline,sig)`); `executeBare(...)` is the
  explicit opt-in to the raw, unauthenticated door.
- Per-account nonce in a **namespaced slot** `keccak256("FleetExecutor.nonce")` salted by the account,
  so it cannot alias another delegate the same EOA installs, nor the EOA's own storage.

Errors: `BadSignature`, `BadNonce`, `Expired`, `NotSelf`, `NotSelfOrIntent`, `ValueMismatch`,
`CallFailed(target)`, `UnsupportedMode(mode)`, `Locked`.

## ⚠ The doors — signed vs 7821 (GOTCHA #203)

Nothing is identical in security posture across these:

| door | auth | replay | spends EOA native |
|---|---|---|---|
| signed `execute(Call[],nonce,deadline,sig)` | EIP-712 `ecrecover==address(this)` | blocked (nonce) | yes, with value |
| `executeSelf` | `msg.sender==address(this)` | n/a | yes |
| `execute(bytes32,bytes)` (7821, default) | **self OR a valid intent** | blocked when intent-supplied | no (caller-funded) |
| `executeBare(bytes32,bytes)` (7821, opt-in) | **NONE — permissionless** | **NOT blocked** | no (caller-funded) |

**The finding (#203):** the bare 7821 entry gates nothing, so on a 7702 EOA it is a permissionless
remote-exec — a stranger makes the EOA `approve(stranger, MAX)` then `transferFrom` its whole ERC-20
balance (or plain `transfer` it out) with zero user signature, and the same batch replays.

**Decision (option 1 of the review): GATE the default door.** Nothing is deployed, so the gate is free
and the drain is a real fund path. The default `execute(bytes32,bytes)` now requires **self OR a valid
EIP-712 intent** (5-arg overload); the old always-permissionless behaviour is preserved as the explicit
opt-in `executeBare(bytes32,bytes)` — a named raw door, matching the standard's intent and the fleet's
siblings. Anything 7821 is **caller-funded** (`msg.value >= Σvalue`), so it never spends the EOA's own
native. Pinned by `test_7821_*` (incl. the exact negcontrol: the call that *was* accepted now reverts,
the same batch *with an intent* still passes).

## Files

```
src/FleetExecutor.sol            the delegate
src/interfaces/IFleetExecutor.sol  consumer shape (call digest ON the EOA)
src/interfaces/Counter.sol       test target
test/unit/FleetExecutor.t.sol    21 tests (incl. #203 gate + negcontrol + drain-path)
test/unit/ExecutorAdversarial.t.sol  reviewer's 5 probes (kept)
test/unit/ExecutorDrainProbe.t.sol   reviewer's 3 drain probes (kept)
```

## Tests — 29/29 pass

Happy path (relayed signed batch in the user's frame; multi-call ordered), replay rejected, expired
rejected, wrong-signer rejected, tampered calls rejected, tampered per-call value rejected,
underfunded value rejected, inner failure propagates, executeSelf path + NotSelf, ERC-7821 modes +
unknown-mode revert, domain binds the EOA (not the impl), nonce is in the namespaced slot, and the
#203 gate set (stranger-no-sig reverts, self passes, stranger+intent passes, `executeBare` still
permissionless, drain-path closed on the default door) + the exact #203 negcontrol.
**Negcontrol:** a mutant with the `ecrecover` check dropped accepts an attacker-signed batch while the
real executor rejects it (proves teeth), and the real executor accepts the user's own signature. The
reviewer's 8 adversarial/drain probes are kept as independent teeth.

```
forge build   # clean
forge test    # 29 passed; 0 failed
```
