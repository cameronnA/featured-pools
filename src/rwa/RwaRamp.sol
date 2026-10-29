// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Ramp} from "../core/Ramp.sol";
import {MarketCalendar} from "./MarketCalendar.sol";
import {SessionLib} from "./SessionLib.sol";

/// @notice RWA-market Ramp with an on-chain US-equity session calendar.
/// @dev LP accounting is inherited from Ramp; only autonomous fee policy differs.
contract RwaRamp is Ramp {
    MarketCalendar public immutable marketCalendar;
    event DayOverridesSet(PoolId indexed poolId, uint256 indexed yearMonth, uint64 packed);
    event DstModeSet(PoolId indexed poolId, SessionLib.DstMode mode);
    event SessionHoursSet(PoolId indexed poolId, uint32 openSec, uint32 closeSec);
    event EarlyCloseSet(PoolId indexed poolId, uint256 year, uint256 month, uint256 day, uint32 closeSec);
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint8 public constant MAX_SPIKE_MULT = 20;
    uint32 public constant MAX_DESCENT_WINDOW = 6 hours;

    mapping(PoolId => SessionLib.FloorConfig) private floorConfigs;

    error RwaConfigRequired();

    event PoolConfigured(PoolId indexed poolId, SessionLib.FloorConfig config, uint24 maxFee);

    constructor(IPoolManager manager_, address authority_, uint24 absoluteMaxFee_)
        Ramp(manager_, authority_, absoluteMaxFee_)
    {
        marketCalendar = new MarketCalendar(address(this));
    }

    /// @notice Disable the crypto-only flat configuration route on RWA hooks.
    function setPoolConfig(PoolKey calldata, uint24, uint24, uint24) external override restricted {
        revert RwaConfigRequired();
    }

    /// @notice Sets the autonomous RWA fee curve and the hard fee cap for a pool.
    function setPoolConfig(PoolKey calldata key, SessionLib.FloorConfig calldata config, uint24 cap)
        external
        restricted
    {
        _checkOwnPool(key);
        if (!key.fee.isDynamicFee() || cap < MIN_POOL_FEE || cap > ABSOLUTE_MAX_FEE) {
            revert InvalidMaxFee();
        }
        marketCalendar.validateFloorConfig(config, cap);

        PoolId id = key.toId();
        floorConfigs[id] = config;

        uint24 floor = config.openFloor;
        if (config.overnightFloor < floor) floor = config.overnightFloor;
        if (config.closedFloor < floor) floor = config.closedFloor;
        _setConfig(id, floor, config.openFloor, cap);
        emit PoolConfigured(id, config, cap);
    }

    function setSessionHours(PoolId id, uint32 o, uint32 e) external restricted {
        _config(id);
        _writeCalendar();
        emit SessionHoursSet(id, o, e);
    }

    function setDayOverrides(PoolId id, uint256 yearMonth, uint64 packed) external restricted {
        _config(id);
        _writeCalendar();
        emit DayOverridesSet(id, yearMonth, packed);
    }

    function setDstMode(PoolId id, SessionLib.DstMode mode) external restricted {
        _config(id);
        _writeCalendar();
        emit DstModeSet(id, mode);
    }

    function setEarlyClose(PoolId id, uint256 y, uint256 m, uint256 d, uint32 e) external restricted {
        _config(id);
        _writeCalendar();
        emit EarlyCloseSet(id, y, m, d, e);
    }

    /// @dev Authorized setters above share their selectors/arguments with the immutable calendar.
    /// Keep access/config checks and event emission on the hook; only forward the component call.
    function _writeCalendar() private {
        address target = address(marketCalendar);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            if iszero(call(gas(), target, 0, ptr, calldatasize(), 0, 0)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            mstore(0x40, and(add(add(ptr, calldatasize()), 31), not(31)))
        }
    }

    function openSec(PoolId id) external view returns (uint32) {
        _readCalendar();
    }

    function closeSec(PoolId id) external view returns (uint32) {
        _readCalendar();
    }

    function dstMode(PoolId id) external view returns (SessionLib.DstMode) {
        _readCalendar();
    }

    function earlyClose(PoolId id, uint256 y, uint256 m, uint256 d) external view returns (uint32) {
        _readCalendar();
    }

    function dayOverride(PoolId id, uint256 y, uint256 m, uint256 d)
        external
        view
        returns (MarketCalendar.DayOverride)
    {
        _readCalendar();
    }

    function sessionAt(PoolId id, uint256 timestamp) external view returns (SessionLib.Session) {
        _readCalendar();
    }

    function feeFloorAt(PoolId, SessionLib.FloorConfig memory, uint256) external view returns (uint256) {
        _readCalendar();
    }

    /// @dev These read-only entry points have identical selectors and ABI on the component.
    /// Assembly returns the component's ABI bytes directly, avoiding duplicate tuple encoders.
    function _readCalendar() private view {
        address target = address(marketCalendar);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := staticcall(gas(), target, ptr, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)
            if ok { return(ptr, size) }
            revert(ptr, size)
        }
    }

    function floorConfig(PoolId id) external view returns (SessionLib.FloorConfig memory) {
        _config(id);
        return floorConfigs[id];
    }

    function _baseFee(PoolId id) internal view override returns (uint256) {
        _config(id);
        return marketCalendar.feeFloorAt(id, floorConfigs[id], block.timestamp);
    }
}
