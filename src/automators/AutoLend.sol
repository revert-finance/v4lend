// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {Automator} from "./Automator.sol";

/// @title AutoLend
/// @notice When a position goes out of range, removes all liquidity and deposits idle token into ERC4626 vault.
/// When near range again, withdraws and creates a one-sided position.
/// NOT available for vault-owned (leveraged) positions.
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

    /// @notice Tracks which addresses are active lend vault (share token) addresses
    mapping(address => bool) public isLendVault;

    /// @notice Per-position configuration
    mapping(uint256 => PositionConfig) public positionConfigs;

    /// @notice Per-position lending state
    mapping(uint256 => LendState) public lendStates;

    struct DepositParams {
        uint256 tokenId;
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        uint256 deadline;
        uint64 rewardX64;
        bytes hookData;
    }

    struct WithdrawParams {
        uint256 tokenId;
        uint256 deadline;
        bytes hookData;
    }

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        address _operator,
        address _withdrawer
    ) Automator(_positionManager, _universalRouter, _zeroxAllowanceHolder, _permit2, _operator, _withdrawer) {}

    /// @notice Owner configures which ERC4626 vault to use per token
    function setAutoLendVault(address token, IERC4626 vault) external onlyOwner {
        // Remove old vault from tracking
        address oldVault = address(autoLendVaults[token]);
        if (oldVault != address(0)) {
            isLendVault[oldVault] = false;
        }
        // Set new vault
        autoLendVaults[token] = vault;
        if (address(vault) != address(0)) {
            isLendVault[address(vault)] = true;
        }
        emit SetAutoLendVault(token, vault);
    }

    /// @notice Operator triggers deposit when position is out of range
    function deposit(DepositParams calldata params) external nonReentrant {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }

        PositionConfig memory config = positionConfigs[params.tokenId];
        if (!config.isActive) {
            revert NotConfigured();
        }
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }

        // Cannot be vault-owned
        address posOwner = IERC721(address(positionManager)).ownerOf(params.tokenId);
        if (vaults[posOwner]) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        int24 tickLower = positionInfo.tickLower();
        int24 tickUpper = positionInfo.tickUpper();

        // Get current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));

        // Verify out of range by tick zone amount
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

        // Remove all liquidity
        (uint256 amount0, uint256 amount1) = _decreaseLiquidity(
            params.tokenId, liquidity, params.amountRemoveMin0, params.amountRemoveMin1, params.deadline, params.hookData
        );

        // Determine idle token (token0 if tick above range, token1 if below)
        Currency idleToken = isAbove ? poolKey.currency1 : poolKey.currency0;
        Currency activeToken = isAbove ? poolKey.currency0 : poolKey.currency1;
        uint256 idleAmount = isAbove ? amount1 : amount0;
        uint256 activeAmount = isAbove ? amount0 : amount1;

        address idleTokenAddr = Currency.unwrap(idleToken);
        IERC4626 lendVault = autoLendVaults[idleTokenAddr];
        if (address(lendVault) == address(0)) {
            revert NotConfigured();
        }

        // Deduct reward
        uint256 reward = idleAmount * params.rewardX64 / Q64;
        idleAmount -= reward;

        // Deposit into ERC4626 vault
        SafeERC20.forceApprove(IERC20(idleTokenAddr), address(lendVault), idleAmount);
        uint256 shares = lendVault.deposit(idleAmount, address(this));
        SafeERC20.forceApprove(IERC20(idleTokenAddr), address(lendVault), 0);

        // Store lend state
        lendStates[params.tokenId] = LendState({
            lentToken: idleTokenAddr,
            shares: shares,
            amount: idleAmount,
            vault: address(lendVault)
        });

        // Send active token to position owner
        _transferToken(posOwner, activeToken, activeAmount, true);

        emit AutoLendDeposit(params.tokenId, idleTokenAddr, idleAmount, shares);
    }

    /// @notice Operator triggers withdrawal when position is near range again
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

        // Snapshot balances before execution to avoid paying out prior protocol rewards
        uint256 balance0Before = poolKey.currency0.balanceOfSelf();
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();

        int24 tickLower = positionInfo.tickLower();
        int24 tickUpper = positionInfo.tickUpper();
        int24 tickWidth = tickUpper - tickLower;
        int24 tickSpacing = poolKey.tickSpacing;

        // Get current tick
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, PoolIdLibrary.toId(poolKey));
        int24 baseTick = (currentTick / tickSpacing) * tickSpacing;
        if (currentTick < 0 && currentTick % tickSpacing != 0) {
            baseTick -= tickSpacing;
        }

        // Check withdrawal trigger zones
        bool isToken0Lent = state.lentToken == Currency.unwrap(poolKey.currency0);
        if (isToken0Lent) {
            // Token0 was lent (tick was above range). Withdraw when tick comes back near range.
            if (currentTick >= tickUpper + config.upperTickZoneWithdraw) {
                revert NotReady(); // Still too far above
            }
        } else {
            // Token1 was lent (tick was below range). Withdraw when tick comes back near range.
            if (currentTick < tickLower - config.lowerTickZoneWithdraw) {
                revert NotReady(); // Still too far below
            }
        }

        // Redeem shares from ERC4626 vault
        uint256 redeemedAmount = IERC4626(state.vault).redeem(state.shares, address(this), address(this));

        // Protocol reward is the vault yield gain — add to balanceBefore so leftover delta excludes it
        uint256 protocolReward = redeemedAmount > state.amount ? redeemedAmount - state.amount : 0;
        uint256 depositAmount = redeemedAmount - protocolReward;
        if (isToken0Lent) {
            balance0Before += protocolReward;
        } else {
            balance1Before += protocolReward;
        }

        // Cannot be vault-owned
        address posOwner = IERC721(address(positionManager)).ownerOf(params.tokenId);

        uint256 newTokenId;

        // Add liquidity based on current tick vs position ticks (mirrors hook logic)
        if (isToken0Lent) {
            // Token0 was lent. Need to check if we can add it back.
            if (baseTick < tickLower) {
                // Current tick below position - can add token0 to existing position
                _handleApproval(permit2, poolKey.currency0, depositAmount);
                _increaseLiquidityOnExisting(
                    params.tokenId, poolKey, positionInfo, depositAmount, 0, params.deadline, params.hookData
                );
            } else {
                // Current tick within/above position - mint new one-sided position above current tick
                _handleApproval(permit2, poolKey.currency0, depositAmount);
                newTokenId = _mintOneSidedPosition(
                    poolKey,
                    baseTick + tickSpacing,
                    baseTick + tickSpacing + tickWidth,
                    depositAmount,
                    0,
                    params.deadline,
                    params.hookData
                );
            }
        } else {
            // Token1 was lent. Need to check if we can add it back.
            if (baseTick >= tickUpper) {
                // Current tick above position - can add token1 to existing position
                _handleApproval(permit2, poolKey.currency1, depositAmount);
                _increaseLiquidityOnExisting(
                    params.tokenId, poolKey, positionInfo, 0, depositAmount, params.deadline, params.hookData
                );
            } else {
                // Current tick within/below position - mint new one-sided position below current tick
                _handleApproval(permit2, poolKey.currency1, depositAmount);
                newTokenId = _mintOneSidedPosition(
                    poolKey,
                    baseTick - tickWidth,
                    baseTick,
                    0,
                    depositAmount,
                    params.deadline,
                    params.hookData
                );
            }
        }

        // Clear lend state
        delete lendStates[params.tokenId];

        if (newTokenId > 0) {
            // Copy config to new position
            positionConfigs[newTokenId] = config;
            delete positionConfigs[params.tokenId];
            // Send new NFT to owner
            IERC721(address(positionManager)).safeTransferFrom(address(this), posOwner, newTokenId);
        }

        // Send leftover tokens to owner (only delta from this execution, excluding protocol rewards)
        uint256 balance0After = poolKey.currency0.balanceOfSelf();
        uint256 balance1After = poolKey.currency1.balanceOfSelf();
        uint256 leftover0 = balance0After > balance0Before ? balance0After - balance0Before : 0;
        uint256 leftover1 = balance1After > balance1Before ? balance1After - balance1Before : 0;
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
        uint256 deadline,
        bytes calldata hookData
    ) internal {
        uint128 liquidity =
            _calculateLiquidity(positionInfo.tickLower(), positionInfo.tickUpper(), poolKey, amount0, amount1);

        (bytes memory actions, bytes[] memory params_array) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.INCREASE_LIQUIDITY), poolKey.currency0, poolKey.currency1
        );
        params_array[0] =
            abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, hookData);

        positionManager.modifyLiquidities{value: _getNativeAmount(poolKey.currency0, poolKey.currency1, amount0, amount1)}(
            abi.encode(actions, params_array), deadline
        );
    }

    function _mintOneSidedPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint256 deadline,
        bytes calldata hookData
    ) internal returns (uint256 newTokenId) {
        uint128 liquidity = _calculateLiquidity(tickLower, tickUpper, poolKey, amount0, amount1);

        (bytes memory actions, bytes[] memory params_array) = _buildActionsForIncreasingLiquidity(
            uint8(Actions.MINT_POSITION), poolKey.currency0, poolKey.currency1
        );
        params_array[0] = abi.encode(
            poolKey, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, address(this), hookData
        );

        positionManager.modifyLiquidities{value: _getNativeAmount(poolKey.currency0, poolKey.currency1, amount0, amount1)}(
            abi.encode(actions, params_array), deadline
        );

        newTokenId = positionManager.nextTokenId() - 1;
    }

    /// @notice Withdraws token balance (accumulated protocol rewards), skipping lend vault share tokens
    function withdrawBalances(address[] calldata tokens, address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        for (; i < count; ++i) {
            address token = tokens[i];
            if (isLendVault[token]) {
                continue;
            }
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance != 0) {
                _transferToken(to, Currency.wrap(token), balance, true);
            }
        }
    }

    /// @notice Position owner configures auto-lend
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        // Cannot be vault-owned
        if (vaults[owner]) {
            revert Unauthorized();
        }
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        // Disallow positions where pool tokens are lend vault share tokens
        if (config.isActive) {
            (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
            if (isLendVault[Currency.unwrap(poolKey.currency0)] || isLendVault[Currency.unwrap(poolKey.currency1)]) {
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
