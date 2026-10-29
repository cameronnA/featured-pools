// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Shared Uniswap v4 permission and dynamic-fee policy for Ramp hooks.
abstract contract BaseHook is IHooks, AccessManaged, ImmutableState {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    uint24 public constant MIN_POOL_FEE = 100;
    uint16 public constant MAX_POKE_DISCOUNT_BPS = 5000;
    uint40 public constant MAX_POKE_TTL = 72 hours;

    struct Config {
        uint24 floorPips;
        uint24 flatPips;
        uint24 maxFee;
        bool set;
    }

    struct Poke {
        uint24 fee0For1;
        uint24 fee1For0;
        uint40 expiry;
    }
    uint24 public immutable ABSOLUTE_MAX_FEE;

    struct Asymmetry {
        uint24 premiumPips;
        bool premiumZeroForOne;
    }
    mapping(PoolId => Asymmetry) internal asymmetries;
    mapping(PoolId => Config) internal configs;
    mapping(PoolId => Poke) internal pokes;
    error NotDynamicFeePool();
    error PoolNotConfigured();
    error InvalidConfig();
    error InvalidTtl();
    error FeeBelowFloor();
    error FeeAboveCap();
    error InvalidMaxFee();
    error EmptyPoke();
    error PremiumExceedsFeeBand();
    error NativeNotSupported();
    event PoolAsymmetrySet(PoolId indexed poolId, uint24 premiumPips, bool premiumZeroForOne);
    event PoolConfigured(PoolId indexed poolId, uint24 floorPips, uint24 flatPips, uint24 maxFee);
    event FeePoked(PoolId indexed poolId, uint24 fee0For1, uint24 fee1For0, uint40 expiry);
    event PokeCleared(PoolId indexed poolId);

    constructor(IPoolManager manager_, address authority_, uint24 absoluteMaxFee_)
        AccessManaged(authority_)
        ImmutableState(manager_)
    {
        if (absoluteMaxFee_ == 0 || absoluteMaxFee_ > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidMaxFee();
        }
        ABSOLUTE_MAX_FEE = absoluteMaxFee_;
        Hooks.validateHookPermissions(IHooks(address(this)), _permissions());
    }

    /// @notice Configures the autonomous fee and hard boundaries for one dynamic-fee pool.
    function setPoolConfig(PoolKey calldata key, uint24 floorPips, uint24 flatPips, uint24 cap)
        external
        virtual
        restricted
    {
        _checkOwnPool(key);
        if (
            !key.fee.isDynamicFee() || floorPips < MIN_POOL_FEE || floorPips > flatPips || flatPips > cap
                || cap > ABSOLUTE_MAX_FEE
        ) {
            revert InvalidConfig();
        }
        PoolId id = key.toId();
        _setConfig(id, floorPips, flatPips, cap);
        emit PoolConfigured(id, floorPips, flatPips, cap);
    }

    function pokeFee(PoolId id, uint24 fee0For1, uint24 fee1For0, uint40 ttl) external restricted {
        _pokeFee(id, fee0For1, fee1For0, ttl);
    }

    /// @dev Shared by product-specific compatibility entry points. In particular, the
    /// native-asset Crypto ramp exposes Fables' legacy single-fee selector and maps it
    /// to the two directional slots.
    function _pokeFee(PoolId id, uint24 fee0For1, uint24 fee1For0, uint40 ttl) internal {
        Config memory c = _config(id);
        if (ttl == 0 || ttl > MAX_POKE_TTL) revert InvalidTtl();
        if (fee0For1 == 0 && fee1For0 == 0) revert EmptyPoke();
        if ((fee0For1 != 0 && fee0For1 < c.floorPips) || (fee1For0 != 0 && fee1For0 < c.floorPips)) {
            revert FeeBelowFloor();
        }
        if (fee0For1 > c.maxFee || fee1For0 > c.maxFee) revert FeeAboveCap();
        uint40 expiry = uint40(block.timestamp) + ttl;
        pokes[id] = Poke(fee0For1, fee1For0, expiry);
        emit FeePoked(id, fee0For1, fee1For0, expiry);
    }

    function setPoolAsymmetry(PoolKey calldata key, uint24 premiumPips, bool premiumZeroForOne) external restricted {
        _checkOwnPool(key);
        PoolId id = key.toId();
        Config memory c = _config(id);
        if (premiumPips > c.maxFee - c.floorPips) revert PremiumExceedsFeeBand();
        asymmetries[id] = Asymmetry(premiumPips, premiumZeroForOne);
        emit PoolAsymmetrySet(id, premiumPips, premiumZeroForOne);
    }

    function poolAsymmetry(PoolId id) external view returns (uint24 premiumPips, bool premiumZeroForOne) {
        Asymmetry memory a = asymmetries[id];
        return (a.premiumPips, a.premiumZeroForOne);
    }

    function clearPoke(PoolId id) external restricted {
        _config(id);
        delete pokes[id];
        emit PokeCleared(id);
    }

    function flatFee(PoolId id) external view returns (uint24) {
        return _config(id).flatPips;
    }

    function maxFee(PoolId id) external view returns (uint24) {
        return _config(id).maxFee;
    }

    /// @notice Configured floor, distinct from the live 50% execution-time guard.
    function pokeFloor(PoolId id) public view returns (uint24) {
        return _config(id).floorPips;
    }

    function pokeOf(PoolId id) external view returns (uint24 fee0For1, uint24 fee1For0, uint40 expiry) {
        Poke memory p = pokes[id];
        return (p.fee0For1, p.fee1For0, p.expiry);
    }

    function _baseFee(PoolId id) internal view virtual returns (uint256) {
        return _config(id).flatPips;
    }

    function autonomousFee(PoolId id, bool zeroForOne) public view returns (uint256 fee) {
        fee = _baseFee(id);
        Asymmetry memory a = asymmetries[id];
        if (zeroForOne == a.premiumZeroForOne) fee += a.premiumPips;
    }

    function currentFee(PoolId id, bool zeroForOne) public view returns (uint24) {
        Config memory c = _config(id);
        uint256 fee = autonomousFee(id, zeroForOne);
        if (fee > c.maxFee) fee = c.maxFee;
        Poke memory p = pokes[id];
        uint256 side = zeroForOne ? p.fee0For1 : p.fee1For0;
        if (p.expiry > block.timestamp && side != 0) {
            uint256 lower = fee * (10000 - MAX_POKE_DISCOUNT_BPS) / 10000;
            if (lower < c.floorPips) lower = c.floorPips;
            fee = side < lower ? lower : side;
            if (fee > c.maxFee) fee = c.maxFee;
        }
        return uint24(fee);
    }

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!key.fee.isDynamicFee()) {
            revert NotDynamicFeePool();
        }
        _checkKey(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            currentFee(id, params.zeroForOne) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert NotPoolManager();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotPoolManager();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotPoolManager();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert NotPoolManager();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert NotPoolManager();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert NotPoolManager();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotPoolManager();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert NotPoolManager();
    }

    function _config(PoolId id) internal view returns (Config memory c) {
        c = configs[id];
        if (!c.set) {
            revert PoolNotConfigured();
        }
    }

    function _setConfig(PoolId id, uint24 floorPips, uint24 flatPips, uint24 cap) internal {
        if (cap == 0 || cap > ABSOLUTE_MAX_FEE) revert InvalidMaxFee();
        if (floorPips < MIN_POOL_FEE || floorPips > cap) revert InvalidConfig();
        if (asymmetries[id].premiumPips > cap - floorPips) revert PremiumExceedsFeeBand();
        configs[id] = Config(floorPips, flatPips, cap, true);
    }

    function _checkOwnPool(PoolKey memory key) internal view {
        if (address(key.hooks) != address(this)) revert PoolNotConfigured();
    }

    function _checkKey(PoolKey memory key) internal view virtual {
        _checkOwnPool(key);
        _config(key.toId());
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();
        if (Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency1) == address(0)) {
            revert NativeNotSupported();
        }
    }

    function _permissions() private pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions(
            true, false, false, false, false, false, true, false, false, false, false, false, false, false
        );
    }
}
