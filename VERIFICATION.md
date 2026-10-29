# Arc source verification

This repository is the minimal source subset from historical source baseline `8286ad24d301708de4daa2eab8254d96858b63e1` that matches the following Arc deployments.

| Contract | Address | Constructor arguments |
| --- | --- | --- |
| `Ramp` | `0x0d93bdb104bc302da6cb7210da56fd44c5bb6080` | PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, AccessManager `0x293826e7a614169eefb870f24c2900fd586ec7b8`, absolute max fee `1000000` |
| `RwaRamp` | `0x7049b3d3e87ad5dab65caf2a7834e9b7bf582080` | PoolManager `0x8366a39CC670B4001A1121B8F6A443A643e40951`, AccessManager `0x293826e7a614169eefb870f24c2900fd586ec7b8`, absolute max fee `1000000` |

Both sources were submitted and accepted through the Etherscan verification API for Arc (chain ID 5042).

Compiler settings:

- Solidity `0.8.26+commit.8a97fa7a`
- EVM version `cancun`
- optimizer enabled, `runs = 1`
- `viaIR = true`
- metadata bytecode hash `ipfs`

The exact historical deployed contracts do not implement the later optional Mid-block Fee interface.
