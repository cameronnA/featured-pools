# Peach Adaptive Pool Hooks

Minimal Solidity source repository for the Peach Adaptive Pool hooks submitted for Uniswap v4 routing review on Arc. It intentionally excludes routers, Zaps, front-end code, deployment scripts, and unrelated protocol components.

## Arc deployments

| Hook | Address | Submitted pool types |
| --- | --- | --- |
| Ramp | [`0x0d93bdb104bc302da6cb7210da56fd44c5bb6080`](https://arc.etherscan.io/address/0x0d93bdb104bc302da6cb7210da56fd44c5bb6080) | cirBTC/USDC and tBTC/tUSDC |
| RwaRamp | [`0x7049b3d3e87ad5dab65caf2a7834e9b7bf582080`](https://arc.etherscan.io/address/0x7049b3d3e87ad5dab65caf2a7834e9b7bf582080) | RWA token pools |

Both contracts are non-upgradeable Uniswap v4 dynamic-fee hooks. Their source code is verified on ArcScan. The deployed versions in this repository predate the optional Mid-block Fee feature and do not expose Mid-block Fee functionality.

## Scope

The repository contains the two hooks and the shared contracts required to compile them:

- `src/core/Ramp.sol`
- `src/rwa/RwaRamp.sol` and its calendar libraries
- `src/hooks/BaseHook.sol`
- LP ledger and claim-fee policy contracts

Uniswap v4 Core, v4 Periphery, OpenZeppelin, and Forge Standard Library are pinned as Git submodules. No router or Zap source is included.

## Build

```bash
git submodule update --init --recursive
forge build
```

See [VERIFICATION.md](VERIFICATION.md) for the source baseline and compiler settings that match the deployed Arc bytecode.
# featured-pools
# featured-pools
# featured-pools
