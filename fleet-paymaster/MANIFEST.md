# fleet-paymaster — LANE 8 manifest

`forge build` → rc 0 · `forge test` → **32 passed / 0 failed / 0 skipped** (28 own + 4 adversarial by dex-critic)

## md5

```
139e5f3cf705a0c1132c9e77291e0257  src/FleetPaymaster.sol
4eb53e92393973fb3f4c85bd39125bf7  src/interfaces/IEntryPoint.sol
8dc41391a3b40bcc2835d9d12a9bde21  src/interfaces/IPaymaster.sol
9ecf1150869bcb6fb1623f348949079e  src/interfaces/PackedUserOperation.sol
1d3979664f8b9a9031e7637cc78d3d9a  src/utils/Owned.sol
2103b1427badcebf95002f48f2a8ca80  src/utils/ReentrancyGuard.sol
55d6fe0bbb3b08c1c93732d1cecc0882  test/mocks/MockEntryPoint.sol
4638798d87a256bd223c04d48e9f4926  test/unit/FleetPaymaster.t.sol
8ac99f7e5bbb8f449aa75b67666d8689  test/unit/PaymasterAdversarial.t.sol
e397c7dded5ccc5e3d92ecf565ccf97a  README.md
fb8ee35593a6fc7cd650f39122d25ae8  foundry.toml
c5bffb897bc82c8a9bce95b5134996cd  remappings.txt
```

Nothing deployed. `owner` is an address; caller (Safe/timelock) out of scope.
