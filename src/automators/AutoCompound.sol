// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IVault} from "../interfaces/IVault.sol";
import {Automator} from "./Automator.sol";

/// @title AutoCompound
/// @notice Allows operators to compound fees or harvest them to a single token.
/// Positions need to be approved (approve or setApprovalForAll) for the contract when outside vault.
/// When position is inside Vault - owner needs to approve the position to be transformed by the contract.
contract AutoCompound is Automator {
    event AutoCompound(
        uint256 indexed tokenId,
        address account,
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1,
        bool harvest
    );

    event PositionConfigured(uint256 indexed tokenId, uint64 maxRewardX64, bool onlyFees);

    event BalanceAdded(uint256 tokenId, address token, uint256 amount);
    event BalanceRemoved(uint256 tokenId, address token, uint256 amount);
    event BalanceWithdrawn(uint256 tokenId, address token, address to, uint256 amount);

    struct PositionConfig {
        uint64 maxRewardX64;
        bool onlyFees;
    }

    mapping(uint256 => PositionConfig) public positionConfigs;

    enum CompoundMode {
        AUTO_COMPOUND,
        HARVEST_TOKENS,
        HARVEST_TOKEN_0,
        HARVEST_TOKEN_1
    }

    /// @notice Per-position leftover balances
    mapping(uint256 => mapping(address => uint256)) public positionBalances;

    /// @notice Total leftover balances across all positions, per token
    mapping(address => uint256) public totalPositionBalances;

    constructor(
        IPositionManager _positionManager,
        address _universalRouter,
        address _zeroxAllowanceHolder,
        IPermit2 _permit2,
        address _operator,
        address _withdrawer
    ) Automator(_positionManager, _universalRouter, _zeroxAllowanceHolder, _permit2, _operator, _withdrawer) {}

    struct ExecuteParams {
        uint256 tokenId;
        CompoundMode mode;
        bool swap0To1;
        uint256 amountIn;
        uint256 amountOutMin;
        bytes swapData;
        uint256 deadline;
        bytes hookData;
        uint64 rewardX64;
    }

    /// @notice Adjust token (which is in a Vault) - via transform method
    function executeWithVault(ExecuteParams calldata params, address vault) external {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(params.tokenId, address(this), abi.encodeCall(this.execute, (params)));
    }

    /// @notice Adjust token directly or via vault transform
    function execute(ExecuteParams calldata params) external nonReentrant {
        if (!operators[msg.sender]) {
            if (vaults[msg.sender]) {
                _validateCaller(positionManager, params.tokenId);
            } else {
                revert Unauthorized();
            }
        }

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(params.tokenId);
        Currency token0 = poolKey.currency0;
        Currency token1 = poolKey.currency1;
        address token0Addr = Currency.unwrap(token0);
        address token1Addr = Currency.unwrap(token1);

        // Collect fees (decrease liquidity by 0)
        (uint256 feeAmount0, uint256 feeAmount1) =
            _decreaseLiquidity(params.tokenId, 0, 0, 0, params.deadline, params.hookData);

        // Deduct protocol reward (stays in contract for withdrawer)
        PositionConfig memory config = positionConfigs[params.tokenId];
        if (params.rewardX64 > config.maxRewardX64) {
            revert ExceedsMaxReward();
        }
        uint256 amount0 = feeAmount0 + positionBalances[params.tokenId][token0Addr];
        uint256 amount1 = feeAmount1 + positionBalances[params.tokenId][token1Addr];
        (amount0, amount1) = _deductReward(feeAmount0, feeAmount1, amount0, amount1, config.onlyFees, params.rewardX64);

        uint256 a0;
        uint256 a1;
        if (params.mode == CompoundMode.AUTO_COMPOUND) {
            (a0, a1) = _executeAutoCompound(params, poolKey, positionInfo, token0, token1, token0Addr, token1Addr, amount0, amount1);
        } else {
            (a0, a1) = _executeHarvest(params, token0, token1, token0Addr, token1Addr, amount0, amount1);
        }

        emit AutoCompound(
            params.tokenId,
            msg.sender,
            a0, a1,
            token0Addr,
            token1Addr,
            params.mode != CompoundMode.AUTO_COMPOUND
        );
    }

    function _executeAutoCompound(
        ExecuteParams calldata params,
        PoolKey memory poolKey,
        PositionInfo positionInfo,
        Currency token0,
        Currency token1,
        address token0Addr,
        address token1Addr,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 compounded0, uint256 compounded1) {
        // Optional swap to rebalance
        if (params.amountIn != 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                RouterSwapParams(
                    params.swap0To1 ? token0 : token1,
                    params.swap0To1 ? token1 : token0,
                    params.amountIn,
                    params.amountOutMin,
                    params.swapData
                )
            );
            if (params.swap0To1) {
                amount0 -= amountInDelta;
                amount1 += amountOutDelta;
            } else {
                amount1 -= amountInDelta;
                amount0 += amountOutDelta;
            }
        }

        if (amount0 != 0 || amount1 != 0) {
            _handleApproval(permit2, token0, amount0);
            _handleApproval(permit2, token1, amount1);

            uint128 liquidity = _calculateLiquidity(
                positionInfo.tickLower(), positionInfo.tickUpper(), poolKey, amount0, amount1
            );

            (bytes memory actions, bytes[] memory params_array) =
                _buildActionsForIncreasingLiquidity(uint8(Actions.INCREASE_LIQUIDITY), token0, token1);
            params_array[0] = abi.encode(
                params.tokenId, liquidity, type(uint128).max, type(uint128).max, params.hookData
            );

            uint256 balance0Before = token0.balanceOfSelf();
            uint256 balance1Before = token1.balanceOfSelf();

            positionManager.modifyLiquidities{value: _getNativeAmount(token0, token1, amount0, amount1)}(
                abi.encode(actions, params_array), params.deadline
            );

            compounded0 = balance0Before - token0.balanceOfSelf();
            compounded1 = balance1Before - token1.balanceOfSelf();
        }

        // Store leftover (slippage diff) for position owner
        _setBalance(params.tokenId, token0Addr, amount0 - compounded0);
        _setBalance(params.tokenId, token1Addr, amount1 - compounded1);
    }

    function _executeHarvest(
        ExecuteParams calldata params,
        Currency token0,
        Currency token1,
        address token0Addr,
        address token1Addr,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256, uint256) {
        // Perform swap based on harvest mode
        if (params.mode == CompoundMode.HARVEST_TOKEN_0 && amount1 != 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                RouterSwapParams(token1, token0, params.amountIn, params.amountOutMin, params.swapData)
            );
            amount1 -= amountInDelta;
            amount0 += amountOutDelta;
        } else if (params.mode == CompoundMode.HARVEST_TOKEN_1 && amount0 != 0) {
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                RouterSwapParams(token0, token1, params.amountIn, params.amountOutMin, params.swapData)
            );
            amount0 -= amountInDelta;
            amount1 += amountOutDelta;
        }
        // HARVEST_TOKENS: no swap

        // Clear leftover balances
        _setBalance(params.tokenId, token0Addr, 0);
        _setBalance(params.tokenId, token1Addr, 0);

        // Get position owner
        address owner = IERC721(address(positionManager)).ownerOf(params.tokenId);
        if (vaults[owner]) {
            owner = IVault(owner).ownerOf(params.tokenId);
        }

        // Send tokens to owner
        _transferToken(owner, token0, amount0, true);
        _transferToken(owner, token1, amount1, true);

        return (amount0, amount1);
    }

    /// @notice Withdraws leftover token balance for a position
    /// @param tokenId Id of position to withdraw
    /// @param to Address to send to
    function withdrawLeftoverBalances(uint256 tokenId, address to) external nonReentrant {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        if (vaults[owner]) {
            owner = IVault(owner).ownerOf(tokenId);
        }
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        address token0Addr = Currency.unwrap(poolKey.currency0);
        address token1Addr = Currency.unwrap(poolKey.currency1);

        uint256 balance0 = positionBalances[tokenId][token0Addr];
        if (balance0 != 0) {
            _withdrawBalanceInternal(tokenId, token0Addr, to, balance0);
        }
        uint256 balance1 = positionBalances[tokenId][token1Addr];
        if (balance1 != 0) {
            _withdrawBalanceInternal(tokenId, token1Addr, to, balance1);
        }
    }

    /// @notice Withdraws ETH balance excluding reserved position leftovers
    function withdrawETH(address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 balance = address(this).balance;
        uint256 reserved = totalPositionBalances[address(0)];
        uint256 available = balance > reserved ? balance - reserved : 0;
        if (available != 0) {
            (bool sent,) = to.call{value: available}("");
            if (!sent) {
                revert EtherSendFailed();
            }
            emit ETHWithdrawn(to, available);
        }
    }

    /// @notice Withdraws token balances excluding reserved position leftovers
    function withdrawBalances(address[] calldata tokens, address to) external override {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        for (; i < count; ++i) {
            address token = tokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 reserved = totalPositionBalances[token];
            uint256 available = balance > reserved ? balance - reserved : 0;
            if (available != 0) {
                _transferToken(to, Currency.wrap(token), available, true);
            }
        }

        emit BalancesWithdrawn(tokens, to);
    }

    function _setBalance(uint256 tokenId, address token, uint256 amount) internal {
        uint256 currentBalance = positionBalances[tokenId][token];
        if (amount != currentBalance) {
            positionBalances[tokenId][token] = amount;
            if (amount > currentBalance) {
                totalPositionBalances[token] += (amount - currentBalance);
                emit BalanceAdded(tokenId, token, amount - currentBalance);
            } else {
                totalPositionBalances[token] -= (currentBalance - amount);
                emit BalanceRemoved(tokenId, token, currentBalance - amount);
            }
        }
    }

    function _withdrawBalanceInternal(uint256 tokenId, address token, address to, uint256 amount) internal {
        positionBalances[tokenId][token] -= amount;
        totalPositionBalances[token] -= amount;
        emit BalanceRemoved(tokenId, token, amount);
        _transferToken(to, Currency.wrap(token), amount, false);
        emit BalanceWithdrawn(tokenId, token, to, amount);
    }

    /// @notice Configure fee parameters for a position
    function configToken(uint256 tokenId, PositionConfig calldata config) external {
        address owner = IERC721(address(positionManager)).ownerOf(tokenId);
        if (vaults[owner]) {
            owner = IVault(owner).ownerOf(tokenId);
        }
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        positionConfigs[tokenId] = config;
        emit PositionConfigured(tokenId, config.maxRewardX64, config.onlyFees);
    }
}
