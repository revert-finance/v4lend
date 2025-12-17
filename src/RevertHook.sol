// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PositionInfoLibrary, PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";

import {LiquidityCalculator} from "./LiquidityCalculator.sol";
import {Transformer} from "./transformers/Transformer.sol";
import {IVault} from "./interfaces/IVault.sol";
import {V4Oracle} from "./V4Oracle.sol";
import {TickLinkedList} from "./lib/TickLinkedList.sol";

import "forge-std/console.sol";

error Unauthorized();
error InvalidConfig();

/// @title RevertHook
/// @notice Hook that allows to add LP Positions via PositionManager and enables auto-compounding, auto-exiting, auto-ranging and auto-lending of positions
/// @dev Positions are not owned by the hook - they are owned by users directly or the vault with the correct permissions
contract RevertHook is Transformer, BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using TickLinkedList for TickLinkedList.List;
    // events for auto actions
    event AutoCompound(
        uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1
    );
    event AutoExit(uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1);
    event AutoRange(
        uint256 indexed tokenId,
        uint256 newTokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1
    );
    event AutoLendDeposit(uint256 indexed tokenId, Currency currency, uint256 amount, uint256 shares);
    event AutoLendWithdraw(uint256 indexed tokenId, Currency currency, uint256 amount, uint256 shares);
    event AutoLendForceExit(uint256 indexed tokenId, Currency currency, uint256 amount, uint256 shares);

    // events for other actions
    event SetPositionConfig(uint256 indexed tokenId, PositionConfig positionConfig);
    event SendLeftoverTokens(
        uint256 indexed tokenId, Currency currency0, Currency currency1, uint256 amount0, uint256 amount1, address recipient
    );
    event SendRewards(
        uint256 indexed tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient
    );
    event SendProtocolFee(uint256 indexed tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        address recipient);

    // special events for swap failures / modifyLiquidities failures
    event HookSwapFailed(PoolKey poolKey, SwapParams swapParams, bytes reason);
    event HookModifyLiquiditiesFailed(bytes actions, bytes[] params, bytes reason);
    event HookAutoLendFailed(address vault, Currency currency, bytes reason);

    IPermit2 public immutable permit2;
    mapping(address => bool) private permit2Approved;

    IPositionManager public immutable positionManager;
    V4Oracle public immutable v4Oracle;

    // last processed tick for pool in _afterSwap
    mapping(PoolId => int24) public tickLowerLasts;

    // manages ticks where actions are triggered (can be multiple entries per tokenid)
    mapping(PoolId poolId => TickLinkedList.List) public lowerTriggerAfterSwap;
    mapping(PoolId poolId => TickLinkedList.List) public upperTriggerAfterSwap;

    // configured vaults for auto lend
    mapping(address token => IERC4626 vault) public autoLendVaults;

    // fees for auto compound execution 1% reward - of fees autocompounded / harvested
    uint16 public constant autoCompoundRewardBps = 100;

    // protocol fees (taken from the fees collected while position is active)
    uint16 public protocolFeeBps = 200;
    address public protocolFeeRecipient;

    // oracle price validation
    int24 public maxTicksFromOracle = 100; // Maximum number of ticks allowed from oracle tick (1%)

    constructor(address protocolFeeRecipient_, IPermit2 _permit2, V4Oracle _v4Oracle)
        BaseHook(_v4Oracle.poolManager())
        Ownable(msg.sender)
    {
        positionManager = _v4Oracle.positionManager();
        protocolFeeRecipient = protocolFeeRecipient_;
        permit2 = _permit2;
        v4Oracle = _v4Oracle;
    }

    mapping(uint256 tokenId => PositionConfig positionConfig) public positionConfigs;
    mapping(uint256 tokenId => AutoRangeConfig autoRangeConfig) public autoRangeConfigs;
    mapping(uint256 tokenId => AutoExitConfig autoExitConfig) public autoExitConfigs;
    mapping(uint256 tokenId => AutoLendConfig autoLendConfig) public autoLendConfigs;

    mapping(uint256 tokenId => PositionState positionState) public positionStates;

    enum PositionMode {
        NONE,
        AUTO_COMPOUND_ONLY,
        AUTO_RANGE,
        AUTO_EXIT,
        AUTO_EXIT_AND_AUTO_RANGE,
        AUTO_LEND
    }

    enum AutoCompoundMode {
        NONE,
        AUTO_COMPOUND,
        HARVEST_TOKEN_0,
        HARVEST_TOKEN_1
    }

    struct PositionState {
        uint32 lastCollect;
        uint32 acumulatedActiveTime;
        uint32 lastActivated;

        address autoLendToken;
        uint256 autoLendShares;
        uint256 autoLendAmount;
    }

    struct PositionConfig {
        PositionMode mode;
        AutoCompoundMode autoCompoundMode;

        // reference pool key data for swaps (can be the same pool or different pool)
        uint24 swapPoolFee;
        int24 swapPoolTickSpacing;
        IHooks swapPoolHooks;

        // TODO proportional fee handling - depending on the time the position is active, the fees are collected proportionally


        // TODO implement max price impact checks for swaps
        //uint32 maxPriceImpact0; // swaps token 0 to token 1
        //uint32 maxPriceImpact1; // swaps token 1 to token 0
    }

    struct AutoExitConfig {
        bool isRelative; // if true, the auto exit tick is relative to the position limits, if false, the auto exit tick is absolute
        int24 autoExitTickLower;
        int24 autoExitTickUpper;
        bool autoExitSwapLower;
        bool autoExitSwapUpper;
    }

    struct AutoRangeConfig {
        int24 autoRangeLowerLimit;
        int24 autoRangeUpperLimit;
        int24 autoRangeLowerDelta;
        int24 autoRangeUpperDelta;
    }

    struct AutoLendConfig {
        int24 autoLendToleranceTick;
    }

    /// @notice Sets the ERC4626 vault for a given token address
    /// @dev Can only be called by the owner. This vault will be used for autolend functionality.
    /// @param token The token address to set the vault for
    /// @param vault The ERC4626 vault address (can be address(0) to remove)
    function setAutoLendVault(address token, IERC4626 vault) external onlyOwner {
        // can only be set once - otherwise could brake existing positions
        if (address(autoLendVaults[token]) == address(0)) {
            autoLendVaults[token] = vault;
        }
    }

    function setMaxTicksFromOracle(int24 _maxTicksFromOracle) external onlyOwner {
        maxTicksFromOracle = _maxTicksFromOracle;
    }

    function setPositionConfig(uint256 tokenId, PositionConfig calldata positionConfig) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        _setPositionConfig(tokenId, positionConfig);
    }

    function _disablePosition(uint256 tokenId) internal {
        _setPositionConfig(tokenId, PositionConfig({
            mode: PositionMode.NONE,
            autoCompoundMode: AutoCompoundMode.NONE,
            swapPoolFee: 0,
            swapPoolTickSpacing: 0,
            swapPoolHooks: IHooks(address(0))
        }));
    }

    function _setPositionConfig(uint256 tokenId, PositionConfig memory positionConfig) internal {
         // handle activation and deactivation
        PositionMode previousMode = positionConfigs[tokenId].mode;
        bool activated = previousMode == PositionMode.NONE && positionConfig.mode != PositionMode.NONE;
        if (activated) {
            positionStates[tokenId].lastActivated = uint32(block.timestamp);
        } else {
            bool deactivated = previousMode != PositionMode.NONE && positionConfig.mode == PositionMode.NONE;
            if (deactivated) {
                positionStates[tokenId].acumulatedActiveTime += uint32(block.timestamp) - positionStates[tokenId].lastActivated;
            }
            positionStates[tokenId].lastActivated = 0; // mark as deactivated
        }

        // update position config
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        _removePositionTriggers(tokenId, poolKey);
        positionConfigs[tokenId] = positionConfig;
        _addPositionTriggers(tokenId, poolKey);

        // emit event
        emit SetPositionConfig(tokenId, positionConfig);
    }

    function setAutoExitConfig(uint256 tokenId, AutoExitConfig calldata config) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (address(poolKey.hooks) != address(this)) {
            revert Unauthorized();
        }

        if (config.autoExitTickLower % poolKey.tickSpacing != 0 && config.autoExitTickLower != type(int24).min) {
            revert InvalidConfig();
        }
        if (config.autoExitTickUpper % poolKey.tickSpacing != 0 && config.autoExitTickUpper != type(int24).max) {
            revert InvalidConfig();
        }

        _removePositionTriggers(tokenId, poolKey);
        autoExitConfigs[tokenId] = config;
        _addPositionTriggers(tokenId, poolKey);
    }

    function setAutoRangeConfig(uint256 tokenId, AutoRangeConfig calldata config) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (address(poolKey.hooks) != address(this)) {
            revert Unauthorized();
        }

        if (config.autoRangeLowerLimit % poolKey.tickSpacing != 0 && config.autoRangeLowerLimit != type(int24).min) {
            revert InvalidConfig();
        }
        if (config.autoRangeUpperLimit % poolKey.tickSpacing != 0 && config.autoRangeUpperLimit != type(int24).max) {
            revert InvalidConfig();
        }
        if (config.autoRangeLowerDelta % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }
        if (config.autoRangeUpperDelta % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }

        _removePositionTriggers(tokenId, poolKey);
        autoRangeConfigs[tokenId] = config;
        _addPositionTriggers(tokenId, poolKey);
    }

    function setAutoLendConfig(uint256 tokenId, AutoLendConfig calldata autoLendConfig) external {
        if (_getOwner(tokenId, true) != msg.sender) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (address(poolKey.hooks) != address(this)) {
            revert Unauthorized();
        }

        if (autoLendConfig.autoLendToleranceTick % poolKey.tickSpacing != 0) {
            revert InvalidConfig();
        }

        _removePositionTriggers(tokenId, poolKey);
        autoLendConfigs[tokenId] = autoLendConfig;
        _addPositionTriggers(tokenId, poolKey);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        tickLowerLasts[key.toId()] = tickLower;
        return BaseHook.afterInitialize.selector;
    }

    function _afterSwap(address caller, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // swaps triggered by the hook itself are just executed
        if (caller == address(this)) {
            return (this.afterSwap.selector, 0);
        }

        PoolId poolId = key.toId();
        int24 tick = tickLowerLasts[poolId];
        int24 tickEnd = _getTickLower(_getTick(poolId), key.tickSpacing);

        console.log("tick", tick);
        console.log("tickEnd", tickEnd);

        if (tick == tickEnd) {
            return (this.afterSwap.selector, 0);
        }

        TickLinkedList.List storage list =
            tick < tickEnd ? upperTriggerAfterSwap[poolId] : lowerTriggerAfterSwap[poolId];

        int24 oracleMaxEndTick = type(int24).min;

        bool exists;
        (exists, tick) = list.searchFirstAfter(tick);

        console.log("exists", exists);
        console.log("tick", tick);

        while (true) {
            if (!exists || (list.increasing ? tick > tickEnd : tick < tickEnd)) {
                break;
            }

            // if not yet calculated maxEndTick
            if (oracleMaxEndTick == type(int24).min) {
                // only do processing until oracle validated end tick
                oracleMaxEndTick = _getOracleMaxEndTick(key, list.increasing);
                tickEnd = list.increasing
                    ? (oracleMaxEndTick < tickEnd ? oracleMaxEndTick : tickEnd)
                    : (oracleMaxEndTick > tickEnd ? oracleMaxEndTick : tickEnd);
                if (list.increasing ? tick > tickEnd : tick < tickEnd) {
                    break;
                }
            }

            console.log("processing tick", tick);

            // execute all triggers at this tick
            uint256 length = list.tokenIds[tick].length;
            for (uint256 i = 0; i < length; i++) {
                _handleTokenIdAfterSwap(key, poolId, list.tokenIds[tick][i], list.increasing, tick);
            }

            // tickEnd may have increased into list direction after the processing of the tokenId (because of swaps - autorange / autoexit will only do swaps in the same direcction)
            tickEnd = _getTickLower(_getTick(poolId), key.tickSpacing);
            tickEnd = list.increasing
                ? (oracleMaxEndTick < tickEnd ? oracleMaxEndTick : tickEnd)
                : (oracleMaxEndTick > tickEnd ? oracleMaxEndTick : tickEnd);

            int24 nextTick;
            (exists, nextTick) = list.getNext(tick);
            list.remove(tick, 0);
            tick = nextTick;
        }

        tickLowerLasts[poolId] = tickEnd;
        return (this.afterSwap.selector, 0);
    }

    // handle token id - when detected as triggered by a swap
    function _handleTokenIdAfterSwap(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger, int24 tick)
        internal
    {
        PositionMode mode = positionConfigs[tokenId].mode;
        if (mode == PositionMode.AUTO_EXIT) {
            _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            // only works with absolute auto exit ticks
            AutoExitConfig memory config = autoExitConfigs[tokenId];
            bool isAutoExitTriggered = isUpperTrigger && tick == config.autoExitTickUpper || !isUpperTrigger && tick == config.autoExitTickLower;            
            if (isAutoExitTriggered) {
                _handleAutoExit(poolKey, poolId, tokenId, isUpperTrigger);
            } else {
                _handleAutoRange(poolKey, poolId, tokenId, isUpperTrigger);
            }
        } else if (mode == PositionMode.AUTO_LEND) {
            _handleAutoLend(poolKey, poolId, tokenId, isUpperTrigger);
        } else if (mode == PositionMode.AUTO_RANGE) {
            _handleAutoRange(poolKey, poolId, tokenId, isUpperTrigger);
        }
    }

    function _handleAutoExit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        address owner = _getOwner(tokenId, false);
        bool ownedByVault = vaults[owner];

        AutoExitConfig memory config = autoExitConfigs[tokenId];

        if (!isUpperTrigger) {
            if (ownedByVault) {
                IVault(owner)
                    .transform(
                        tokenId,
                        address(this),
                        abi.encodeCall(
                            this.autoExit, (poolKey, poolId, tokenId, isUpperTrigger, config.autoExitSwapLower)
                        )
                    );
            } else {
                autoExit(poolKey, poolId, tokenId, isUpperTrigger, config.autoExitSwapLower);
            }
        } else if (isUpperTrigger) {
            if (ownedByVault) {
                IVault(owner)
                    .transform(
                        tokenId,
                        address(this),
                        abi.encodeCall(
                            this.autoExit, (poolKey, poolId, tokenId, isUpperTrigger, config.autoExitSwapUpper)
                        )
                    );
            } else {
                autoExit(poolKey, poolId, tokenId, isUpperTrigger, config.autoExitSwapUpper);
            }
        }

        _removePositionTriggers(tokenId, poolKey);
    }

    function _handleAutoLend(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        // no auto lend for collateral positions
        bool ownedByVault = vaults[_getOwner(tokenId, false)];
        if (ownedByVault) {
            return;
        }

        uint256 shares = positionStates[tokenId].autoLendShares;
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        if (shares > 0) {
            _autoLendWithdraw(poolKey, tokenId, shares);
        } else {
            _autoLendDeposit(poolKey, poolId, tokenId, isUpperTrigger);
        }
    }

    function _handleAutoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpperTrigger) internal {
        address owner = _getOwner(tokenId, false);
        bool ownedByVault = vaults[owner];

        if (ownedByVault) {
            IVault(owner).transform(tokenId, address(this), abi.encodeCall(this.autoRange, (poolKey, poolId, tokenId)));
        } else {
            autoRange(poolKey, poolId, tokenId);
        }
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        // only allow positions created via PositionManager or the hook itself
        if (sender != address(positionManager) && sender != address(this)) {
            revert Unauthorized();
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {

        console.log("afterAddLiquidity");

        uint256 tokenId = uint256(params.salt);

        feeDelta = _takeProtocolFees(tokenId, key, feeDelta);

        // if the hook itself is adding liquidity, dont configure anything
        if (sender == address(this)) {
            return (BaseHook.afterAddLiquidity.selector, feeDelta);
        }
        
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        // if adding from 0
        if (int128(liquidity) == params.liquidityDelta) {
            _addPositionTriggers(tokenId, key);
        }

        return (BaseHook.afterAddLiquidity.selector, feeDelta);
    }

    /// @notice When liquidity is removed, the hook will take a percentage of the fees
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {

        console.log("afterRemoveLiquidity");

        uint256 tokenId = uint256(params.salt);
        feeDelta = _takeProtocolFees(tokenId, key, feeDelta);

        // if the hook itself is removing liquidity, dont configure anything
        if (sender == address(this)) {
            return (BaseHook.afterRemoveLiquidity.selector, feeDelta);
        }

       
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        // remove the position from the lists
        if (liquidity == 0) {
            _removePositionTriggers(tokenId, key);
        }

        return (BaseHook.afterRemoveLiquidity.selector, feeDelta);
    }

    function _takeProtocolFees(uint256 tokenId, PoolKey calldata key, BalanceDelta feeDelta) internal returns (BalanceDelta newFeeDelta) {

        address feeRecipient = protocolFeeRecipient;
        uint32 accumulatedActiveTime = positionStates[tokenId].acumulatedActiveTime;
        uint32 lastActivated = positionStates[tokenId].lastActivated;
        if (lastActivated > 0) {
            accumulatedActiveTime += uint32(block.timestamp) - lastActivated;
            positionStates[tokenId].lastActivated = uint32(block.timestamp);
        }
        uint32 lastCollect = positionStates[tokenId].lastCollect;
        uint32 feeTime = lastCollect == 0 ? 0 : uint32(block.timestamp) - lastCollect;

        console.log("accumulatedActiveTime", accumulatedActiveTime);
        console.log("feeTime", feeTime);

        positionStates[tokenId].lastCollect = uint32(block.timestamp);

        // if no time has passed, or no active time has been accumulated, return 0 fees
        if (feeTime == 0 || accumulatedActiveTime == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }

        PoolId poolId = key.toId();

        int128 protocolFee0 = int32(accumulatedActiveTime) * feeDelta.amount0() * int16(protocolFeeBps) / (10000 * int32(feeTime));
        int128 protocolFee1 = int32(accumulatedActiveTime) * feeDelta.amount1() * int16(protocolFeeBps) / (10000 * int32(feeTime));

        // take protocol fees
        if (protocolFee0 > 0) {
            poolManager.take(key.currency0, feeRecipient, uint256(int256(protocolFee0)));
        }
        if (protocolFee1 > 0) {
            poolManager.take(key.currency1, feeRecipient, uint256(int256(protocolFee1)));
        }

        emit SendProtocolFee(tokenId, key.currency0, key.currency1, uint256(int256(protocolFee0)), uint256(int256(protocolFee1)), feeRecipient);

        newFeeDelta = toBalanceDelta(protocolFee0, protocolFee1);
    }

    // add position triggers - called when a position is created or when a position is increased, or when config is changed
    function _addPositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {

        PositionMode mode = positionConfigs[tokenId].mode;
        if (mode == PositionMode.NONE || mode == PositionMode.AUTO_COMPOUND_ONLY) {
            return;
        }

        PoolId poolId = poolKey.toId();

        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();

        TickLinkedList.List storage lowerList = lowerTriggerAfterSwap[poolId];
        TickLinkedList.List storage upperList = upperTriggerAfterSwap[poolId];

        // ensure the list is increasing (if not, set it to true - only once in first use)
        if (!upperList.increasing) {
            upperList.increasing = true;
        }

        if (mode == PositionMode.AUTO_RANGE || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            if (autoRangeConfigs[tokenId].autoRangeLowerLimit != type(int24).min) {
                lowerList.insert(tickLower - autoRangeConfigs[tokenId].autoRangeLowerLimit, tokenId);
            }
            if (autoRangeConfigs[tokenId].autoRangeUpperLimit != type(int24).max) {
                upperList.insert(tickUpper + autoRangeConfigs[tokenId].autoRangeUpperLimit, tokenId);
            }
        } 
        if (mode == PositionMode.AUTO_EXIT || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            if (autoExitConfigs[tokenId].isRelative) {
                if (autoExitConfigs[tokenId].autoExitTickLower != type(int24).min) {
                    lowerList.insert(tickLower - autoExitConfigs[tokenId].autoExitTickLower, tokenId);
                }
                if (autoExitConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                    upperList.insert(tickUpper + autoExitConfigs[tokenId].autoExitTickUpper, tokenId);
                }
            } else {
                if (autoExitConfigs[tokenId].autoExitTickLower != type(int24).min) {
                    lowerList.insert(autoExitConfigs[tokenId].autoExitTickLower, tokenId);
                }
                if (autoExitConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                    upperList.insert(autoExitConfigs[tokenId].autoExitTickUpper, tokenId);
                }
            }
        }
        if (mode == PositionMode.AUTO_LEND) {
            if (positionStates[tokenId].autoLendShares > 0) {
                if (Currency.unwrap(poolKey.currency0) == positionStates[tokenId].autoLendToken) {
                    upperList.insert(
                        tickLower - autoLendConfigs[tokenId].autoLendToleranceTick - poolKey.tickSpacing, tokenId
                    );
                } else {
                    lowerList.insert(tickUpper + autoLendConfigs[tokenId].autoLendToleranceTick, tokenId);
                }
            } else {
                lowerList.insert(
                    tickLower - autoLendConfigs[tokenId].autoLendToleranceTick * 2 - poolKey.tickSpacing, tokenId
                );
                upperList.insert(tickUpper + autoLendConfigs[tokenId].autoLendToleranceTick * 2, tokenId);
            }
        }
    }

    function _removePositionTriggers(uint256 tokenId, PoolKey memory poolKey) internal {
        PositionMode mode = positionConfigs[tokenId].mode;

        if (mode == PositionMode.NONE || mode == PositionMode.AUTO_COMPOUND_ONLY) {
            return;
        }

        PoolId poolId = poolKey.toId();
        (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();

        if (mode == PositionMode.AUTO_RANGE || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            if (autoRangeConfigs[tokenId].autoRangeLowerLimit != type(int24).min) {
                lowerTriggerAfterSwap[poolId].remove(tickLower - autoRangeConfigs[tokenId].autoRangeLowerLimit, tokenId);
            }
            if (autoRangeConfigs[tokenId].autoRangeUpperLimit != type(int24).max) {
                upperTriggerAfterSwap[poolId].remove(tickUpper + autoRangeConfigs[tokenId].autoRangeUpperLimit, tokenId);
            }
        } 
        if (mode == PositionMode.AUTO_EXIT || mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            if (autoExitConfigs[tokenId].isRelative) {
                if (autoExitConfigs[tokenId].autoExitTickLower != type(int24).min) {
                lowerTriggerAfterSwap[poolId].remove(tickLower - autoExitConfigs[tokenId].autoExitTickLower, tokenId);
                }
                if (autoExitConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                    upperTriggerAfterSwap[poolId].remove(tickUpper + autoExitConfigs[tokenId].autoExitTickUpper, tokenId);
                }
            } else {
                if (autoExitConfigs[tokenId].autoExitTickLower != type(int24).min) {
                    lowerTriggerAfterSwap[poolId].remove(autoExitConfigs[tokenId].autoExitTickLower, tokenId);
                }
                if (autoExitConfigs[tokenId].autoExitTickUpper != type(int24).max) {
                    upperTriggerAfterSwap[poolId].remove(autoExitConfigs[tokenId].autoExitTickUpper, tokenId);
                }
            }
        }
        if (mode == PositionMode.AUTO_LEND) {
            if (positionStates[tokenId].autoLendShares > 0) {
                if (Currency.unwrap(poolKey.currency0) == positionStates[tokenId].autoLendToken) {
                    upperTriggerAfterSwap[poolId].remove(
                        tickLower - autoLendConfigs[tokenId].autoLendToleranceTick - poolKey.tickSpacing, tokenId
                    );
                } else {
                    lowerTriggerAfterSwap[poolId].remove(
                        tickUpper + autoLendConfigs[tokenId].autoLendToleranceTick, tokenId
                    );
                }
            } else {
                lowerTriggerAfterSwap[poolId].remove(
                    tickLower - autoLendConfigs[tokenId].autoLendToleranceTick * 2 - poolKey.tickSpacing, tokenId
                );
                upperTriggerAfterSwap[poolId].remove(
                    tickUpper + autoLendConfigs[tokenId].autoLendToleranceTick * 2, tokenId
                );
            }
        }
    }

    /// @notice Returns the owner of the position
    /// @param tokenId The token ID of the position
    /// @param isRealOwner If true, the real owner is returned, if false, the direct owner of the token is returned (maybe a vault)
    /// @return The owner of the position
    function _getOwner(uint256 tokenId, bool isRealOwner) internal view returns (address) {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);

        if (isRealOwner && vaults[owner]) {
            return IVault(owner).ownerOf(tokenId);
        } else {
            return owner;
        } 
    }

    function _getCrossedTicks(PoolId poolId, int24 tickSpacing)
        internal
        view
        returns (int24 tickLower, int24 lower, int24 upper)
    {
        tickLower = _getTickLower(_getTick(poolId), tickSpacing);
        int24 tickLowerLast = tickLowerLasts[poolId];

        if (tickLower < tickLowerLast) {
            lower = tickLower + tickSpacing;
            upper = tickLowerLast;
        } else {
            lower = tickLowerLast;
            upper = tickLower - tickSpacing;
        }
    }

    function _getTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(poolManager, poolId);
    }

    function _getTickLower(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _getSwapPoolKey(uint256 tokenId, PoolKey memory poolKey) internal view returns (PoolKey memory) {
        uint24 swapPoolFee = positionConfigs[tokenId].swapPoolFee;
        int24 swapPoolTickSpacing = positionConfigs[tokenId].swapPoolTickSpacing;
        IHooks swapPoolHooks = positionConfigs[tokenId].swapPoolHooks;

        // if the swap pool key is the same as the configured swap pool key, return the pool key
        if (swapPoolHooks == poolKey.hooks && swapPoolFee == poolKey.fee && swapPoolTickSpacing == poolKey.tickSpacing)
        {
            return poolKey;
        }

        // otherwise, return the configured swap pool key
        return PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: positionConfigs[tokenId].swapPoolFee,
            tickSpacing: positionConfigs[tokenId].swapPoolTickSpacing,
            hooks: positionConfigs[tokenId].swapPoolHooks
        });
    }

    function _autoLendDeposit(PoolKey memory poolKey, PoolId poolId, uint256 tokenId, bool isUpper) internal {
        // remove remaining triggers
        _removePositionTriggers(tokenId, poolKey);

        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        Currency currency = isUpper ? currency1 : currency0;
        address currencyAddr = Currency.unwrap(currency);
        uint256 amount = isUpper ? amount1 : amount0;

        SafeERC20.forceApprove(IERC20(currencyAddr), address(autoLendVaults[currencyAddr]), amount);

        try autoLendVaults[currencyAddr].deposit(amount, address(this)) returns (uint256 shares) {
            positionStates[tokenId].autoLendShares = shares;
            positionStates[tokenId].autoLendToken = currencyAddr;
            positionStates[tokenId].autoLendAmount = amount;

            address owner = _getOwner(tokenId, true);
            _sendLeftoverTokens(tokenId, currency0, currency1, owner);

            _addPositionTriggers(tokenId, poolKey);

            emit AutoLendDeposit(tokenId, currency, amount, shares);
        } catch (bytes memory reason) {
            emit HookAutoLendFailed(address(autoLendVaults[currencyAddr]), currency, reason);
        }

        SafeERC20.forceApprove(IERC20(currencyAddr), address(autoLendVaults[currencyAddr]), 0);
    }

    /// @notice Handles autolend gain calculation and fee distribution
    /// @param tokenId The token ID of the position
    /// @param poolKey The pool key
    /// @param currency The currency that was lent
    /// @param amount The amount received from the vault
    /// @param autoLendAmount The original amount that was lent
    function _handleAutoLendGain(
        uint256 tokenId,
        PoolKey memory poolKey,
        Currency currency,
        uint256 amount,
        uint256 autoLendAmount
    ) internal {
        // send fees corresponding to the protocol fee on gains only
        uint256 autoLendGain = amount > autoLendAmount ? amount - autoLendAmount : 0;
        if (autoLendGain > 0) {
            bool isToken0 = poolKey.currency0 == currency;
            currency.transfer(protocolFeeRecipient, autoLendGain * protocolFeeBps / 10000);
            emit SendProtocolFee(tokenId, poolKey.currency0, poolKey.currency1, isToken0 ? autoLendGain : 0, isToken0 ? 0 : autoLendGain, protocolFeeRecipient);
        }
    }

    /// @notice Resets the auto lend state for a given token ID
    /// @param tokenId The token ID of the position
    function _resetAutoLend(uint256 tokenId) internal {
        positionStates[tokenId].autoLendShares = 0;
        positionStates[tokenId].autoLendToken = address(0);
        positionStates[tokenId].autoLendAmount = 0;
    }

    function _autoLendWithdraw(PoolKey memory poolKey, uint256 tokenId, uint256 shares) internal {
        address token = positionStates[tokenId].autoLendToken;
        try autoLendVaults[token].redeem(shares, address(this), address(this)) returns (uint256 amount) {

            _handleAutoLendGain(tokenId, poolKey, Currency.wrap(token), amount, positionStates[tokenId].autoLendAmount);
            
            (, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

            _handleApproval(Currency.wrap(token), amount);

            uint256 newTokenId;

            int24 baseTick = _getTickLower(_getTick(poolKey.toId()), poolKey.tickSpacing);

            // depending on the available token - create correct position
            if (token == Currency.unwrap(poolKey.currency0)) {
                if (baseTick < posInfo.tickLower()) {
                    _increaseLiquidity(tokenId, poolKey, posInfo, uint128(amount), 0);
                } else {
                    (newTokenId,,) = _mintNewPosition(
                        poolKey,
                        baseTick + poolKey.tickSpacing,
                        baseTick + poolKey.tickSpacing + (posInfo.tickUpper() - posInfo.tickLower()),
                        uint128(amount),
                        0,
                        _getOwner(tokenId, false)
                    );
                }
            } else {
                if (baseTick >= posInfo.tickUpper()) {
                    _increaseLiquidity(tokenId, poolKey, posInfo, 0, uint128(amount));
                } else {
                    (newTokenId,,) = _mintNewPosition(
                        poolKey,
                        baseTick - (posInfo.tickUpper() - posInfo.tickLower()),
                        baseTick,
                        0,
                        uint128(amount),
                        _getOwner(tokenId, false)
                    );
                }
            }

            _resetAutoLend(tokenId);
            _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, _getOwner(tokenId, true));

            if (newTokenId > 0) {
                autoLendConfigs[newTokenId] = autoLendConfigs[tokenId];
                _setPositionConfig(newTokenId, positionConfigs[tokenId]);
                _disablePosition(tokenId);
            } else {
                _addPositionTriggers(tokenId, poolKey);
            }

            emit AutoLendWithdraw(tokenId, Currency.wrap(token), amount, shares);
        } catch (bytes memory reason) {
            emit HookAutoLendFailed(address(autoLendVaults[token]), Currency.wrap(token), reason);
        }
    }

    /// @notice Forces the auto-lend position to exit (in cases when not executed via autoLendWithdraw or user wants to exit early)
    /// @param tokenId The tokenId of the position
    function autoLendForceExit(uint256 tokenId) external {
        address owner = _getOwner(tokenId, true);
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        _removePositionTriggers(tokenId, poolKey);

        uint256 shares = positionStates[tokenId].autoLendShares;
       
        if (shares > 0) {
            address token = positionStates[tokenId].autoLendToken;
            uint256 autoLendAmount = positionStates[tokenId].autoLendAmount;
            uint256 amount = autoLendVaults[token].redeem(shares, address(this), address(this));

            _handleAutoLendGain(tokenId, poolKey, Currency.wrap(token), amount, autoLendAmount);
            _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, owner);

            emit AutoLendForceExit(tokenId, Currency.wrap(token), amount, shares);
        }

        _resetAutoLend(tokenId);
        _disablePosition(tokenId);
    }

    function autoExit(
        PoolKey memory poolKey,
        PoolId,
        /* poolId */
        uint256 tokenId,
        bool isUpper,
        bool doSwap
    )
        public
    {
        // validate caller (can be vault or poolmanager)
        if (msg.sender != address(poolManager)) {
            if (vaults[msg.sender]) {
                _validateCaller(positionManager, tokenId);
            } else {
                revert Unauthorized();
            }
        }

        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        if (doSwap) {
            uint256 swapAmount = !isUpper ? amount0 : amount1;
            PoolKey memory swapPoolKey = _getSwapPoolKey(tokenId, poolKey);
            BalanceDelta swapDelta = _swap(swapPoolKey, !isUpper, swapAmount);
            (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);
        }

        _sendLeftoverTokens(tokenId, currency0, currency1, _getOwner(tokenId, true));

        _disablePosition(tokenId);

        emit AutoExit(tokenId, currency0, currency1, amount0, amount1);
    }

    function autoRange(PoolKey memory poolKey, PoolId poolId, uint256 tokenId) public {
        // validate caller (can be vault or poolmanager)
        if (msg.sender != address(poolManager)) {
            if (vaults[msg.sender]) {
                _validateCaller(positionManager, tokenId);
            } else {
                revert Unauthorized();
            }
        }

        int24 baseTick = _getTickLower(_getTick(poolId), poolKey.tickSpacing);

        (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1) = _decreaseLiquidity(tokenId, false);

        int24 tickLower = baseTick + autoRangeConfigs[tokenId].autoRangeLowerDelta;
        int24 tickUpper = baseTick + autoRangeConfigs[tokenId].autoRangeUpperDelta;

        (amount0, amount1) = _swapToOptimalRange(tokenId, poolKey, poolId, tickLower, tickUpper, amount0, amount1);

        _handleApproval(currency0, amount0);
        _handleApproval(currency1, amount1);

        uint256 newTokenId;

        (newTokenId, amount0, amount1) =
            _mintNewPosition(poolKey, tickLower, tickUpper, uint128(amount0), uint128(amount1), _getOwner(tokenId, false));

        _sendLeftoverTokens(tokenId, currency0, currency1, _getOwner(tokenId, true));

        // configure new position
        autoRangeConfigs[newTokenId] = autoRangeConfigs[tokenId];
        if (positionConfigs[tokenId].mode == PositionMode.AUTO_EXIT_AND_AUTO_RANGE) {
            autoExitConfigs[newTokenId] = autoExitConfigs[tokenId];
        }
        _setPositionConfig(newTokenId, positionConfigs[tokenId]);
        _disablePosition(tokenId);

        emit AutoRange(tokenId, newTokenId, currency0, currency1, amount0, amount1);
    }

    /// @notice Auto-compounds fees from positions (this can be called by anyone)
    /// @dev Collects fees, swaps to achieve proportions (offchain optimized calculation), and adds liquidity back via PositionManager
    ///      Fees are based on actual added amounts to incentivize optimal swapping
    /// @param tokenIds Array of token IDs to compound
    function autoCompound(uint256[] memory tokenIds) external {
        uint256 length = tokenIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = tokenIds[i];
            // check if position is in vault, if yes call transform on behalf of owner
            address owner = _getOwner(tokenId, false);
            if (vaults[owner]) {
                IVault(owner)
                    .transform(tokenId, address(this), abi.encodeCall(this.autoCompoundForVault, (tokenId, msg.sender)));
            } else {
                poolManager.unlock(abi.encode(tokenId, msg.sender));
            }
        }
    }

    /// @notice Auto-compounds callback function which is called during transform
    function autoCompoundForVault(uint256 tokenId, address caller) external {
        // check if caller is vault, if yes call transform on behalf of owner
        if (!vaults[msg.sender]) {
            revert Unauthorized();
        }
        _validateCaller(positionManager, tokenId);
        poolManager.unlock(abi.encode(tokenId, caller));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // disallow arbitrary caller
        if (msg.sender != address(poolManager)) {
            revert Unauthorized();
        }
        (uint256 tokenId, address caller) = abi.decode(data, (uint256, address));
        _executeAutoCompound(tokenId, caller);
        return bytes("");
    }

    /// @notice Internal function that executes the auto-compound logic
    /// @dev Collects fees, swaps to achieve proportions, and adds liquidity back via PositionManager
    /// @param tokenId The token ID to compound
    /// @param caller The address that initiated the auto-compound (for reward distribution)
    function _executeAutoCompound(uint256 tokenId, address caller) internal {

        AutoCompoundMode mode = positionConfigs[tokenId].autoCompoundMode;
        if (mode == AutoCompoundMode.NONE || positionConfigs[tokenId].mode == PositionMode.NONE) {
            return;
        }

        // Step 1: Get position info
        (PoolKey memory poolKey, PositionInfo posInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // Step 2: Collect fees only (don't remove liquidity)
        (,, uint256 fees0, uint256 fees1) = _decreaseLiquidity(tokenId, true);

        if (fees0 == 0 && fees1 == 0) {
            return; // No fees to compound
        }

        if (mode == AutoCompoundMode.AUTO_COMPOUND) {
            // Step 3: Swap to optimal range
            (fees0, fees1) = _swapToOptimalRange(
                tokenId, poolKey, poolKey.toId(), posInfo.tickLower(), posInfo.tickUpper(), fees0, fees1
            );
        } else if (mode == AutoCompoundMode.HARVEST_TOKEN_0) {
            BalanceDelta swapDelta = _swap(poolKey, false, fees1);
            (fees0, fees1) = _applyBalanceDelta(swapDelta, fees0, fees1);
        } else if (mode == AutoCompoundMode.HARVEST_TOKEN_1) {
            BalanceDelta swapDelta = _swap(poolKey, true, fees0);
            (fees0, fees1) = _applyBalanceDelta(swapDelta, fees0, fees1);
        }

        (fees0, fees1) = _sendRewards(tokenId, poolKey.currency0, poolKey.currency1, fees0, fees1, autoCompoundRewardBps, caller);

        _handleApproval(poolKey.currency0, fees0);
        _handleApproval(poolKey.currency1, fees1);

        if (mode == AutoCompoundMode.AUTO_COMPOUND) {
            // Step 4: Add liquidity
            (fees0, fees1) = _increaseLiquidity(tokenId, poolKey, posInfo, uint128(fees0), uint128(fees1));
        }

        // Step 5: Send leftover tokens (or harvested tokens) to owner 
        _sendLeftoverTokens(tokenId, poolKey.currency0, poolKey.currency1, _getOwner(tokenId, true));
    }

    /// @notice Swaps to optimal range using LiquidityCalculator
    function _swapToOptimalRange(
        uint256 tokenId,
        PoolKey memory poolKey,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256, uint256) {
        LiquidityCalculator.V4PoolInfo memory poolInfo = LiquidityCalculator.V4PoolInfo({
            poolMgr: poolManager, poolIdentifier: poolId, tickSpacing: poolKey.tickSpacing
        });

        PoolKey memory swapPoolKey = _getSwapPoolKey(tokenId, poolKey);

        uint256 inputAmount;
        bool swapDir0to1;
        if (
            swapPoolKey.hooks == poolKey.hooks && swapPoolKey.fee == poolKey.fee
                && swapPoolKey.tickSpacing == poolKey.tickSpacing
        ) {
            (inputAmount,, swapDir0to1,) =
                LiquidityCalculator.calculateSamePool(poolInfo, tickLower, tickUpper, amount0, amount1);
        } else {
            (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
            (inputAmount,, swapDir0to1) =
                LiquidityCalculator.calculateSimple(sqrtPrice, tickLower, tickUpper, amount0, amount1, swapPoolKey.fee);
        }

        if (inputAmount > 0) {
            BalanceDelta swapDelta = _swap(swapPoolKey, swapDir0to1, inputAmount);
            (amount0, amount1) = _applyBalanceDelta(swapDelta, amount0, amount1);
        }

        return (amount0, amount1);
    }

    /// @notice Adds liquidity to an existing position using PositionManager
    /// @dev Uses INCREASE_LIQUIDITY action to add liquidity back to position
    /// @param tokenId The position NFT token ID
    /// @param poolKey The pool key
    /// @param posInfo The position info
    /// @param available0 Available amount of token0
    /// @param available1 Available amount of token1
    /// @return amount0Added Actual amount of token0 added to the position
    /// @return amount1Added Actual amount of token1 added to the position
    function _increaseLiquidity(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo posInfo,
        uint128 available0,
        uint128 available1
    ) internal returns (uint256 amount0Added, uint256 amount1Added) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // Record balances before adding liquidity
        amount0Added = currency0.balanceOfSelf();
        amount1Added = currency1.balanceOfSelf();

        // Calculate liquidity from available amounts
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());

        int24 tickLower = posInfo.tickLower();
        int24 tickUpper = posInfo.tickUpper();

        // Calculate liquidity from available amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );

        if (liquidity == 0) {
            return (0, 0);
        }

        // Use INCREASE_LIQUIDITY and SETTLE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        // INCREASE_LIQUIDITY params: (tokenId, liquidity, amount0Max, amount1Max, hookData)
        params_array[0] = abi.encode(
            tokenId,
            liquidity,
            type(uint128).max, // limited by liquidity
            type(uint128).max, // limited by liquidity
            bytes("") // hookData
        );

        // SETTLE_PAIR params: (currency0, currency1, payer)
        params_array[1] = abi.encode(currency0, currency1, address(this));

        // Execute via PositionManager
        try positionManager.modifyLiquiditiesWithoutUnlock(actions, params_array) {
            // Calculate actual amounts added by comparing balances before and after
            amount0Added -= currency0.balanceOfSelf();
            amount1Added -= currency1.balanceOfSelf();
        } catch (bytes memory reason) {
            // emit event
            emit HookModifyLiquiditiesFailed(actions, params_array, reason);
            // Return zero amounts on failure
            amount0Added = 0;
            amount1Added = 0;
        }
    }

    /// @notice Mints a new position using PositionManager
    /// @dev Uses MINT_POSITION action to create a new position with specified tick range
    /// @param poolKey The pool key
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param available0 Available amount of token0
    /// @param available1 Available amount of token1
    /// @param recipient The owner of the new position
    /// @return newTokenId The token ID of the   newly minted position
    /// @return amount0Added Actual amount of token0 added to the position
    /// @return amount1Added Actual amount of token1 added to the position
    function _mintNewPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint128 available0,
        uint128 available1,
        address recipient
    ) internal returns (uint256 newTokenId, uint128 amount0Added, uint128 amount1Added) {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // Get the next token ID before minting
        newTokenId = positionManager.nextTokenId();

        // Record balances before minting
        amount0Added = uint128(currency0.balanceOfSelf());
        amount1Added = uint128(currency1.balanceOfSelf());

        // Calculate liquidity from available amounts
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());

        // Calculate liquidity from available amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            available0,
            available1
        );

        // Use MINT_POSITION and SETTLE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        // MINT_POSITION params: (poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hookData)
        params_array[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            available0,
            available1,
            recipient,
            bytes("") // hookData
        );

        // SETTLE_PAIR params: (currency0, currency1, payer)
        params_array[1] = abi.encode(currency0, currency1, address(this));

        // Execute via PositionManager
        try positionManager.modifyLiquiditiesWithoutUnlock(actions, params_array) {
            // Calculate actual amounts added by comparing balances before and after
            amount0Added -= uint128(currency0.balanceOfSelf());
            amount1Added -= uint128(currency1.balanceOfSelf());

            // mint doesn't call onERC721Received, so we need to notify the vault manually
            if (vaults[recipient]) {
                IVault(recipient).notifyERC721Received(newTokenId, recipient);
            }
        } catch (bytes memory reason) {
            // emit event
            emit HookModifyLiquiditiesFailed(actions, params_array, reason);
            // Return zero amounts on failure
            amount0Added = 0;
            amount1Added = 0;
        }
    }

    /// @notice Decreases full liquidity from a position using PositionManager
    /// @dev Gets position liquidity, then uses modifyLiquidities with DECREASE_LIQUIDITY and TAKE_PAIR actions
    ///      to remove all liquidity and collect tokens/fees
    /// @param tokenId The position NFT token ID
    /// @return currency0 The currency of the token0
    /// @return currency1 The currency of the token1
    /// @return amount0 Amount of token0 received
    /// @return amount1 Amount of token1 received
    function _decreaseLiquidity(uint256 tokenId, bool onlyFees)
        internal
        returns (Currency currency0, Currency currency1, uint256 amount0, uint256 amount1)
    {
        // Step 1: Get position info and current liquidity
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = onlyFees ? 0 : positionManager.getPositionLiquidity(tokenId);

        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;

        // Step 2: Decrease all liquidity using PositionManager
        // 0 liquidity removal only works with INCREASE_LIQUIDITY (because of fee handling in hook - buggy implementation in positionmanager)
        bytes memory actions = abi.encodePacked(onlyFees ? uint8(Actions.INCREASE_LIQUIDITY) : uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params_array = new bytes[](2);

        // INCREASE_LIQUIDITY/DECREASE_LIQUIDITY params: (tokenId, liquidity, amount0Min, amount1Min, hookData)
        params_array[0] = abi.encode(
            tokenId,
            liquidity, // Remove non or all liquidity
            onlyFees ? type(uint128).max : 0,
            onlyFees ? type(uint128).max : 0,
            bytes("") // hookData
        );

        // TAKE_PAIR params: (currency0, currency1, recipient)
        params_array[1] = abi.encode(currency0, currency1, address(this));

        try positionManager.modifyLiquiditiesWithoutUnlock(actions, params_array) {
            // Step 3: Calculate amounts actually received
            amount0 = currency0.balanceOfSelf();
            amount1 = currency1.balanceOfSelf();
        } catch (bytes memory reason) {
            // emit eventx
            emit HookModifyLiquiditiesFailed(actions, params_array, reason);
        }
    }

    /// @notice Executes a swap via poolManager and handles balance deltas
    /// @dev Core swap logic that executes swap, settles owed tokens, and takes received tokens.
    ///      If swap fails, emits SwapFailed event (this may happen for swap pool problems like not enough liquidity)
    /// @param poolKey The pool key
    /// @param zeroForOne True if swapping token0 for token1, false otherwise
    /// @param swapAmount The amount to swap (in the source token)
    /// @return swapDelta The balance delta of the swap
    function _swap(PoolKey memory poolKey, bool zeroForOne, uint256 swapAmount)
        internal
        returns (BalanceDelta swapDelta)
    {
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        // Prepare swap params
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(swapAmount), // exact in
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Execute swap via poolManager - if the swap fails
        try poolManager.swap(poolKey, swapParams, "") returns (BalanceDelta result) {
            swapDelta = result;
            _handleSwapDeltas(poolKey, swapDelta);
        } catch (bytes memory reason) {
            // emit event
            emit HookSwapFailed(poolKey, swapParams, reason);
            // return the swap delta which is 0, 0
        }
    }

    /// @notice Handles swap balance deltas - settles debts and takes received tokens
    /// @dev Extracted from _swap to avoid stack too deep error
    /// @param poolKey The pool key containing currency0 and currency1
    /// @param swapDelta The balance delta from the swap
    function _handleSwapDeltas(PoolKey memory poolKey, BalanceDelta swapDelta) internal {
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        // Handle currency0 delta
        int256 delta0 = swapDelta.amount0();
        if (delta0 < 0) {
            // We owe token0 - settle the debt
            uint256 amount0Owed = uint256(-delta0);
            poolManager.sync(currency0);
            if (currency0.isAddressZero()) {
                poolManager.settle{value: amount0Owed}();
            } else {
                currency0.transfer(address(poolManager), amount0Owed);
                poolManager.settle();
            }
        } else if (delta0 > 0) {
            // We receive token0
            poolManager.take(currency0, address(this), uint256(delta0));
        }

        // Handle currency1 delta
        int256 delta1 = swapDelta.amount1();
        if (delta1 < 0) {
            // We owe token1 - settle the debt
            uint256 amount1Owed = uint256(-delta1);
            poolManager.sync(currency1);
            if (currency1.isAddressZero()) {
                poolManager.settle{value: amount1Owed}();
            } else {
                currency1.transfer(address(poolManager), amount1Owed);
                poolManager.settle();
            }
        } else if (delta1 > 0) {
            // We receive token1
            poolManager.take(currency1, address(this), uint256(delta1));
        }
    }

    function _sendRewards(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 amount0,
        uint256 amount1,
        uint16 feeBps,
        address recipient
    ) internal returns (uint256 newAmount0, uint256 newAmount1) {

        uint256 fee0 = amount0 * feeBps / 10000;
        uint256 fee1 = amount1 * feeBps / 10000;

        if (fee0 != 0) {
            // send protocol fee
            currency0.transfer(recipient, fee0);
        }
        if (fee1 != 0) {
            // send protocol fee
            currency1.transfer(recipient, fee1);
        }

        newAmount0 = amount0 - fee0;
        newAmount1 = amount1 - fee1;

        emit SendRewards(tokenId, currency0, currency1, fee0, fee1, recipient);
    }

    function _sendLeftoverTokens(uint256 tokenId, Currency currency0, Currency currency1, address recipient) internal {
        uint256 amount0 = currency0.balanceOfSelf();
        uint256 amount1 = currency1.balanceOfSelf();
        if (amount0 != 0) {
            currency0.transfer(recipient, amount0);
        }
        if (amount1 != 0) {
            currency1.transfer(recipient, amount1);
        }

        emit SendLeftoverTokens(tokenId, currency0, currency1, amount0, amount1, recipient);
    }

    function _applyBalanceDelta(BalanceDelta balanceDelta, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint256 newAmount0, uint256 newAmount1)
    {
        if (balanceDelta.amount0() < 0) {
            // we spent token0
            newAmount0 = amount0 - uint256(int256(-balanceDelta.amount0()));
        } else {
            newAmount0 = amount0 + uint256(int256(balanceDelta.amount0()));
        }
        if (balanceDelta.amount1() < 0) {
            // we spent token1
            newAmount1 = amount1 - uint256(int256(-balanceDelta.amount1()));
        } else {
            newAmount1 = amount1 + uint256(int256(balanceDelta.amount1()));
        }
    }

    /// @notice Validates and caps the end tick based on oracle price
    /// @param poolKey The pool key
    /// @param up True if swap moves price up (tick increasing), false if swap moves price down (tick decreasing)
    /// @return maxEndTick The maximum end tick allowed based on maxTicksFromOracle
    function _getOracleMaxEndTick(PoolKey memory poolKey, bool up) internal view returns (int24 maxEndTick) {
        uint160 oracleSqrtPriceX96 =
            v4Oracle.getPoolSqrtPriceX96(Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));
        int24 oracleTick = _getTickLower(TickMath.getTickAtSqrtPrice(oracleSqrtPriceX96), poolKey.tickSpacing);

        if (up) {
            maxEndTick = _getTickLower(oracleTick + maxTicksFromOracle, poolKey.tickSpacing);
        } else {
            maxEndTick = _getTickLower(oracleTick - maxTicksFromOracle, poolKey.tickSpacing);
        }
    }

    function _handleApproval(Currency token, uint256 amount) internal {
        if (amount != 0 && !token.isAddressZero()) {
            address tokenAddr = Currency.unwrap(token);
            if (!permit2Approved[tokenAddr]) {
                SafeERC20.forceApprove(IERC20(tokenAddr), address(permit2), type(uint256).max);
                permit2Approved[tokenAddr] = true;
            }
            permit2.approve(tokenAddr, address(positionManager), uint160(amount), uint48(block.timestamp));
        }
    }
}
