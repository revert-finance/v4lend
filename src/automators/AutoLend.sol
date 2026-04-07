// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {AutoLendLib} from "../shared/planning/AutoLendLib.sol";
import {Automator} from "./Automator.sol";

/// @title AutoLend
/// @notice When a position goes out of range, removes all liquidity and deposits idle token into ERC4626 vault.
/// When near range again, withdraws and re-enters liquidity (or mints one-sided position if range changed too much).
/// Only supports non-vault-owned positions.
contract AutoLend is Automator {
    event SetAutoLendVault(address indexed token, IERC4626 vault);
    event AutoLendDeposit(uint256 indexed tokenId, address token, uint256 amount, uint256 shares);
    event AutoLendWithdraw(
        uint256 indexed tokenId, uint256 newTokenId, address token, uint256 amount, uint256 shares
    );
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        int24 lowerTickZone,
        int24 upperTickZone,
        int24 lowerTickZoneWithdraw,
        int24 upperTickZoneWithdraw,
        uint64 maxRewardX64
    );

    struct PositionConfig {
        bool isActive;
        int24 lowerTickZone;
        int24 upperTickZone;
        int24 lowerTickZoneWithdraw;
        int24 upperTickZoneWithdraw;
        uint64 maxRewardX64;
    }

    struct LendState {
        address lentToken;
        uint256 shares;
        uint256 amount;
        address vault;
    }

    /// @notice Owner-configured ERC4626 vaults per token address
    mapping(address => IERC4626) public autoLendVaults;

    /// @notice Tracks active lend positions referencing each vault (vault token == share token)
    mapping(address => uint256) public vaultPositionCount;

    /// @notice Set of all addresses ever registered as lend vaults (never cleared)
    mapping(address => bool) public isKnownVault;

    /// @notice Per-position configuration
    mapping(uint256 => PositionConfig) public positionConfigs;

    /// @notice Per-position lending state
    mapping(uint256 => LendState) public lendStates;

    struct DepositParams {
        uint256 tokenId;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 deadline;
        bytes hookData;
        uint64 rewardX64;
    }

    struct WithdrawParams {
        uint256 tokenId;
        uint256 deadline;
        bytes hookData;
        uint64 rewardX64;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        IV4Oracle _v4Oracle,
        address _operator,
        address _withdrawer
    )
        Automator(
            _positionManager,
            _universalRouter,
            _zeroxAllowanceHolder,
            _permit2,
            _v4Oracle,
            _operator,
            _withdrawer
        )
    {}

    /// @notice Owner configures which ERC4626 vault to use per token
    function setAutoLendVault(address token, IERC4626 vault) external onlyOwner {
        if (address(vault) != address(0)) {
            // Native ETH positions are wrapped to WETH before vault deposit.
            address expectedAsset = token == address(0) ? address(weth) : token;
            address vaultAsset;
            try vault.asset() returns (address assetAddress) {
                vaultAsset = assetAddress;
            } catch {
                revert InvalidConfig();
            }
            if (vaultAsset != expectedAsset) {
                revert InvalidConfig();
            }
        }
        autoLendVaults[token] = vault;
        if (address(vault) != address(0)) {
            isKnownVault[address(vault)] = true;
        }
        emit SetAutoLendVault(token, vault);
    }

    /// @notice Operator triggers deposit when position is out of range
    /// @dev Protocol reward is charged from LP fees only (not principal liquidity amount).
    function deposit(DepositParams calldata params) external nonReentrant {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (!config.isActive) {
            revert NotConfigured();
        }
        if (lendStates[params.tokenId].shares > 0) {
            revert InvalidConfig();
        }

        // Non-vault positions only
        address posOwner = IERC721(address(positionManager)).ownerOf(params.tokenId);
        if (vaults[posOwner]) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        int24 tickLower = positionInfo.tickLower();
        int24 tickUpper = positionInfo.tickUpper();

        // Get current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));

        // Verify out-of-range zone condition
        bool isAbove = currentTick >= tickUpper + config.upperTickZone;
        bool isBelow = currentTick < tickLower - config.lowerTickZone;
        if (!isAbove && !isBelow) {
            revert NotReady();
        }

        // Get full liquidity
        uint128 liquidity = positionManager.getPositionLiquidity(params.tokenId);
        if (liquidity == 0) {
            revert NoLiquidity();
        }

        // Collect fees first (decrease by 0), then remove all liquidity
        (uint256 feeAmount0, uint256 feeAmount1) =
            _decreaseLiquidity(params.tokenId, 0, 0, 0, params.deadline, params.hookData);
        (uint256 liquidityAmount0, uint256 liquidityAmount1) = _decreaseLiquidity(
            params.tokenId,
            liquidity,
            params.amountRemoveMin0,
            params.amountRemoveMin1,
            params.deadline,
            params.hookData
        );

        uint256 amount0 = feeAmount0 + liquidityAmount0;
        uint256 amount1 = feeAmount1 + liquidityAmount1;

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        // Fee basis: LP fees only
        (amount0, amount1) = _deductReward(feeAmount0, feeAmount1, amount0, amount1, true, params.rewardX64);

        // Determine idle token (token0 if tick below range, token1 if above)
        Currency idleToken = isAbove ? poolKey.currency1 : poolKey.currency0;
        Currency activeToken = isAbove ? poolKey.currency0 : poolKey.currency1;
        uint256 idleAmount = isAbove ? amount1 : amount0;
        uint256 activeAmount = isAbove ? amount0 : amount1;

        address idleTokenAddr = Currency.unwrap(idleToken);
        IERC4626 lendVault = autoLendVaults[idleTokenAddr];
        // Backward-compatible fallback for native token configuration keyed by WETH.
        if (address(lendVault) == address(0) && idleToken.isAddressZero()) {
            lendVault = autoLendVaults[address(weth)];
        }
        if (address(lendVault) == address(0)) {
            revert NotConfigured();
        }

        // Deposit into ERC4626 vault (wrap native ETH to WETH first if needed)
        address depositTokenAddr = idleTokenAddr;
        if (idleToken.isAddressZero()) {
            weth.deposit{value: idleAmount}();
            depositTokenAddr = address(weth);
        }
        SafeERC20.forceApprove(IERC20(depositTokenAddr), address(lendVault), idleAmount);
        uint256 shares = lendVault.deposit(idleAmount, address(this));
        SafeERC20.forceApprove(IERC20(depositTokenAddr), address(lendVault), 0);
        if (shares == 0) {
            revert InvalidConfig();
        }

        lendStates[params.tokenId] = LendState({
            lentToken: idleTokenAddr,
            shares: shares,
            amount: idleAmount,
            vault: address(lendVault)
        });
        vaultPositionCount[address(lendVault)]++;

        // Send active token to position owner immediately
        _transferToken(posOwner, activeToken, activeAmount, true);

        emit AutoLendDeposit(params.tokenId, idleTokenAddr, idleAmount, shares);
    }

    /// @notice Operator triggers withdrawal when position is near range again
    /// @dev Protocol reward is charged from generated vault yield only.
    function withdraw(WithdrawParams calldata params) external nonReentrant {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }

        LendState memory state = lendStates[params.tokenId];
        if (state.shares == 0) {
            revert NotConfigured();
        }

        PositionConfig memory config = positionConfigs[params.tokenId];

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);

        // Snapshot balances before this operation to isolate leftovers from this execution only
        uint256 balance0Before = poolKey.currency0.balanceOfSelf();
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();

        int24 tickLower = positionInfo.tickLower();
        int24 tickUpper = positionInfo.tickUpper();
        (uint160 sqrtPriceX96, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));

        // Check withdrawal trigger zones
        bool isToken0Lent = state.lentToken == Currency.unwrap(poolKey.currency0);
        if (isToken0Lent) {
            // Token0 lent when price was below range; withdraw when it comes back up near range
            if (currentTick < tickLower - config.lowerTickZoneWithdraw) {
                revert NotReady();
            }
        } else {
            // Token1 lent when price was above range; withdraw when it comes back down near range
            if (currentTick >= tickUpper + config.upperTickZoneWithdraw) {
                revert NotReady();
            }
        }

        uint256 redeemedAmount = IERC4626(state.vault).redeem(state.shares, address(this), address(this));

        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        // Fee basis: generated yield only
        uint256 rewardAmount;
        {
            uint256 yieldAmount = redeemedAmount > state.amount ? redeemedAmount - state.amount : 0;
            rewardAmount = yieldAmount * params.rewardX64 / Q64;
            if (rewardAmount > redeemedAmount) rewardAmount = redeemedAmount;
            redeemedAmount -= rewardAmount;
        }

        // If lent token is native ETH (stored as WETH in vault), unwrap only the net redeemed amount.
        // Reward remains as WETH protocol fees in this contract.
        if (state.lentToken == address(0)) {
            weth.withdraw(redeemedAmount);
        }

        // Non-vault positions only
        address posOwner = IERC721(address(positionManager)).ownerOf(params.tokenId);
        if (vaults[posOwner]) {
            revert Unauthorized();
        }

        uint256 newTokenId;
        (bool addToExisting, int24 newLower, int24 newUpper) = AutoLendLib.planOneSidedReentry(
            currentTick,
            poolKey.tickSpacing,
            tickLower,
            tickUpper,
            isToken0Lent
        );

        if (addToExisting) {
            _handleApproval(permit2, isToken0Lent ? poolKey.currency0 : poolKey.currency1, redeemedAmount);
            _increaseLiquidityOnExisting(
                params.tokenId,
                poolKey,
                positionInfo,
                isToken0Lent ? redeemedAmount : 0,
                isToken0Lent ? 0 : redeemedAmount,
                sqrtPriceX96,
                params.deadline,
                params.hookData
            );
        } else {
            if (newUpper > TickMath.MAX_TICK) {
                newUpper = TickMath.maxUsableTick(poolKey.tickSpacing);
            }
            if (newLower < TickMath.MIN_TICK) {
                newLower = TickMath.minUsableTick(poolKey.tickSpacing);
            }
            if (newLower >= newUpper) {
                revert InvalidConfig();
            }
            _handleApproval(permit2, isToken0Lent ? poolKey.currency0 : poolKey.currency1, redeemedAmount);
            newTokenId = _mintOneSidedPosition(
                poolKey,
                newLower,
                newUpper,
                isToken0Lent ? redeemedAmount : 0,
                isToken0Lent ? 0 : redeemedAmount,
                sqrtPriceX96,
                params.deadline,
                params.hookData
            );
        }

        // Clear lend state and release vault reference
        vaultPositionCount[state.vault]--;
        delete lendStates[params.tokenId];

        if (newTokenId > 0) {
            // Configuration must follow the migrated position
            positionConfigs[newTokenId] = config;
            delete positionConfigs[params.tokenId];
            // transferFrom avoids safeTransfer callback requirements on recipient contracts
            IERC721(address(positionManager)).transferFrom(address(this), posOwner, newTokenId);
        }

        // Leftovers exclude protocol reward retained in this contract.
        // Native-lent case keeps reward in WETH, so it does not affect currency0(ETH) delta.
        uint256 reward0 = isToken0Lent ? (state.lentToken == address(0) ? 0 : rewardAmount) : 0;
        uint256 reward1 = isToken0Lent ? 0 : rewardAmount;

        uint256 leftover0 = poolKey.currency0.balanceOfSelf() - balance0Before - reward0;
        uint256 leftover1 = poolKey.currency1.balanceOfSelf() - balance1Before - reward1;
        if (leftover0 > 0) {
            _transferToken(posOwner, poolKey.currency0, leftover0, true);
        }
        if (leftover1 > 0) {
            _transferToken(posOwner, poolKey.currency1, leftover1, true);
        }

        emit AutoLendWithdraw(params.tokenId, newTokenId, state.lentToken, redeemedAmount, state.shares);
    }

    function _increaseLiquidityOnExisting(
        uint256 tokenId,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 deadline,
        bytes calldata hookData
    ) internal {
        uint128 liquidity =
            _calculateLiquidity(sqrtPriceX96, positionInfo.tickLower(), positionInfo.tickUpper(), amount0, amount1);

        (bytes memory actions, bytes[] memory paramsArray) =
            _buildActionsForIncreasingLiquidity(uint8(Actions.INCREASE_LIQUIDITY), poolKey.currency0, poolKey.currency1);
        paramsArray[0] = abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, hookData);

        positionManager.modifyLiquidities{value: _getNativeAmount(poolKey.currency0, poolKey.currency1, amount0, amount1)}(
            abi.encode(actions, paramsArray), deadline
        );
    }

    function _mintOneSidedPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 deadline,
        bytes calldata hookData
    ) internal returns (uint256 newTokenId) {
        uint128 liquidity = _calculateLiquidity(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);

        (bytes memory actions, bytes[] memory paramsArray) =
            _buildActionsForIncreasingLiquidity(uint8(Actions.MINT_POSITION), poolKey.currency0, poolKey.currency1);
        paramsArray[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint128).max,
            type(uint128).max,
            address(this),
            hookData
        );

        positionManager.modifyLiquidities{value: _getNativeAmount(poolKey.currency0, poolKey.currency1, amount0, amount1)}(
            abi.encode(actions, paramsArray), deadline
        );

        newTokenId = positionManager.nextTokenId() - 1;
    }

    /// @notice Withdraws token balances, skipping active vault share tokens
    function withdrawBalances(address[] calldata tokens, address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        for (; i < count; ++i) {
            address token = tokens[i];
            // Skip native ETH (use withdrawETH) and active lend vault share tokens
            if (token == address(0) || vaultPositionCount[token] > 0) {
                continue;
            }
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                _transferToken(to, Currency.wrap(token), balance, true);
            }
        }

        emit BalancesWithdrawn(tokens, to);
    }

    /// @notice Position owner configures auto-lend
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);

        // Non-vault positions only
        if (vaults[owner]) {
            revert Unauthorized();
        }
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        if (
            config.lowerTickZone < 0 || config.upperTickZone < 0 || config.lowerTickZoneWithdraw < 0
                || config.upperTickZoneWithdraw < 0
        ) {
            revert InvalidConfig();
        }

        if (config.isActive) {
            // Disallow positions whose pool tokens are lend vault share tokens
            (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
            if (isKnownVault[Currency.unwrap(poolKey.currency0)] || isKnownVault[Currency.unwrap(poolKey.currency1)]) {
                revert InvalidConfig();
            }
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.lowerTickZone,
            config.upperTickZone,
            config.lowerTickZoneWithdraw,
            config.upperTickZoneWithdraw,
            config.maxRewardX64
        );
    }
}
