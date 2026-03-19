// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfoLibrary, PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {Constants} from "../shared/Constants.sol";
import {IV4Oracle} from "./interfaces/IV4Oracle.sol";

// Chainlink Price Feed Interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}


/// @title V4Oracle for Uniswap V4 position valuation using Chainlink feeds
/// @notice Oracle that uses Chainlink feeds to calculate V4 position values for lending/borrowing
/// @dev Validates pool prices against Chainlink oracle prices to prevent price manipulation attacks
/// @custom:security Price Manipulation Protection:
///   - maxPoolPriceDifference enforces pool price must be within X% of Chainlink price
///   - Position values use Chainlink-derived prices, not raw pool prices
///   - Sequencer uptime feed check for L2 networks prevents stale data during outages
/// @custom:security Feed Staleness:
///   - Each token has configurable maxFeedAge to reject stale Chainlink data
///   - Sequencer grace period (10 min) ensures L2 data is fresh after restart
/// @custom:security Trust Assumptions:
///   - Chainlink feeds are trusted as ground truth for prices
///   - Owner is trusted to configure valid feeds and staleness parameters
contract V4Oracle is IV4Oracle, Ownable2Step, Constants {
    uint256 private constant SEQUENCER_GRACE_PERIOD_TIME = 600; // 10mins

    event TokenConfigUpdated(address indexed token, TokenConfig config);
    event SetMaxPoolPriceDifference(uint16 maxPoolPriceDifference);
    event SetSequencerUptimeFeed(address sequencerUptimeFeed);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    
    // Common token used as reference for price calculations (typically WETH/USDC)
    address public immutable referenceToken;
    uint8 public immutable referenceTokenDecimals;

    // Common token used in Chainlink feeds as "pair" (address(0xdead) if USD or other non-token reference)
    address public immutable chainlinkReferenceToken;

    struct TokenConfig {
        AggregatorV3Interface feed; // Chainlink feed
        uint32 maxFeedAge; // Max age of feed data in seconds
        uint8 feedDecimals; // Decimals of the feed
        uint8 tokenDecimals; // Decimals of the token
    }

    // token => config mapping
    mapping(address => TokenConfig) public feedConfigs;

    uint16 public maxPoolPriceDifference; // Max price difference x10000

    // Feed to check sequencer up on L2s - address(0) when not needed
    address public sequencerUptimeFeed;

    /// @dev Constructor for V4Oracle deployment
    /// @notice Initializes the V4Oracle contract with core V4 components
    /// @param _positionManager The Uniswap V4 PositionManager contract instance  
    /// @param _referenceToken Token used as reference for price calculations (typically WETH or USDC)
    /// @param _chainlinkReferenceToken Token used as base currency for Chainlink feeds (typically USD-linked token)
    constructor(
        IPositionManager _positionManager,
        address _referenceToken,
        address _chainlinkReferenceToken
    ) Ownable(msg.sender) {
        poolManager = _positionManager.poolManager();
        positionManager = _positionManager;
        referenceToken = _referenceToken;
        referenceTokenDecimals = IERC20Metadata(_referenceToken).decimals();
        chainlinkReferenceToken = _chainlinkReferenceToken;
    }

    /// @notice Calculates "pool price" using chainlink feeds
    /// @dev Calculates price of a token in quote token terms using Chainlink feeds.
    ///      Reverts if token or quoteToken is not configured (except reference token shortcuts).
    /// @param token0 Token address to get price for (use address(0) for native ETH)
    /// @param token1 Token address to quote the price in (use address(0) for native ETH)
    /// @return priceX96 Price of token in quote token terms in X96
    function getPoolSqrtPriceX96(address token0, address token1) external view returns (uint160) {
        if (token0 == token1) {
            return SafeCast.toUint160(Q96);
        }

        (uint256 price0X96, uint256 chainlinkReferencePriceX96) = _getReferenceTokenPriceX96(token0, 0);
        (uint256 price1X96,) = _getReferenceTokenPriceX96(token1, chainlinkReferencePriceX96);
        return SafeCast.toUint160(Math.sqrt(FullMath.mulDiv(price0X96, Q96, price1X96)) * (2 ** 48));
    }

    /// @notice Gets value of a V4 position in a specific token
    /// @dev Calculates position value using liquidity amount + uncollected fees at current Oracle prices
    /// @param tokenId Token ID of the position NFT to be valued
    /// @param token Token address to quote the position value in (use address(0) for native ETH)
    /// @return value Total value of complete position (liquidity + fees) at Oracle prices in the specified token
    /// @return feeValue Value of uncollected fees only at Oracle prices in the specified token
    /// @return price0X96 Price of token0 normalized to Q96 format in the specified token
    /// @return price1X96 Price of token1 normalized to Q96 format in the specified token
    function getValue(uint256 tokenId, address token)
        external
        view
        override
        returns (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96)
    {
        PositionState memory state = _loadPositionState(tokenId);
        (uint256 amount0, uint256 amount1) = _getAmounts(state);
        (uint128 fees0, uint128 fees1) = _getFees(state);

        // Get price of quote token in reference token
        uint256 priceTokenX96;
        if (state.currency0 == Currency.wrap(token)) {
            priceTokenX96 = state.price0X96;
        } else if (state.currency1 == Currency.wrap(token)) {
            priceTokenX96 = state.price1X96;
        } else {
            (priceTokenX96,) = _getReferenceTokenPriceX96(token, state.cachedChainlinkReferencePriceX96);
        }

        // Calculate outputs
        value = (state.price0X96 * (amount0 + fees0) + state.price1X96 * (amount1 + fees1)) / priceTokenX96;
        feeValue = (state.price0X96 * fees0 + state.price1X96 * fees1) / priceTokenX96;
        price0X96 = FullMath.mulDiv(state.price0X96, Q96, priceTokenX96);
        price1X96 = FullMath.mulDiv(state.price1X96, Q96, priceTokenX96);
    }

    /// @notice Gets liquidity and uncollected fees for a V4 position by tokenId
    /// @dev Calculates current position liquidity and uncollected trading fees following Uniswap V4 methodology
    /// @param tokenId Token ID of the position NFT to analyze
    /// @return liquidity Current liquidity amount remaining in the position
    /// @return fees0 Uncollected token0 fees that have accrued since last collection
    /// @return fees1 Uncollected token1 fees that have accrued since last collection
    function getLiquidityAndFees(uint256 tokenId)
        external
        view
        override
        returns (uint128 liquidity, uint128 fees0, uint128 fees1)
    {
        PositionState memory state = _loadPositionState(tokenId);
        
        // Get position liquidity
        liquidity = state.liquidity;
    
        // Get uncollected fees
        (fees0, fees1) = _getFees(state);
    }

    /// @notice Gets comprehensive breakdown of a V4 position
    /// @dev Returns all essential position data including currencies, liquidity, token amounts, and fees
    /// @param tokenId Token ID of the position NFT to analyze
    /// @return currency0 Currency struct representing token0 of the position (use Currency.unwrap() to get address)
    /// @return currency1 Currency struct representing token1 of the position (use Currency.unwrap() to get address)
    /// @return fee Fee tier of the position in basis points (e.g., 3000 = 0.3%)
    /// @return liquidity Current liquidity amount in the position
    /// @return amount0 Current token amount of token0 based on oracle-derived price
    /// @return amount1 Current token amount of token1 based on oracle-derived price  
    /// @return fees0 Uncollected token0 fees accrued by the position
    /// @return fees1 Uncollected token1 fees accrued by the position
    function getPositionBreakdown(uint256 tokenId)
        external
        view
        override
        returns (
            Currency currency0,
            Currency currency1,
            uint24 fee,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            uint128 fees0,
            uint128 fees1
        )
    {
        PositionState memory state = _loadPositionState(tokenId);
        (amount0, amount1) = _getAmounts(state);
        (fees0, fees1) = _getFees(state);
        liquidity = state.liquidity;
        // Extract basic position data
        currency0 = state.currency0;
        currency1 = state.currency1;
        fee = state.fee;
    }

    /// @notice Sets or updates the Chainlink feed configuration for a token (requires owner privileges)
    /// @dev Configures oracle connection to Chainlink price feed with age verification
    ///      This controls whether the token can be used in:
    ///      - Vault loan valuation/health checks
    ///      - Oracle slippage checks in automators/rehook (when slippage != 10000)
    /// @param token Token address to configure (use address(0) for native ETH)
    /// @param feed Valid Chainlink AggregatorV3Interface contract address for price data
    /// @param maxFeedAge Maximum age of Chainlink feed data in seconds before considering stale
    function setTokenConfig(
        address token,
        AggregatorV3Interface feed,
        uint32 maxFeedAge
    ) external onlyOwner {
        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = address(token) == address(0) ? 18 : IERC20Metadata(token).decimals();

        TokenConfig memory config = TokenConfig(
            feed,
            maxFeedAge,
            feedDecimals,
            tokenDecimals
        );

        feedConfigs[token] = config;
        emit TokenConfigUpdated(token, config);
    }

    /// @notice Sets the maximum price difference parameter for validation (requires owner privileges)
    /// @dev Controls price deviation tolerance between different oracle sources
    /// @param _maxPoolPriceDifference Maximum allowable price difference expressed in basis points ×100 (e.g., 1000 = 10%)
    function setMaxPoolPriceDifference(uint16 _maxPoolPriceDifference) external onlyOwner {
        maxPoolPriceDifference = _maxPoolPriceDifference;
        emit SetMaxPoolPriceDifference(_maxPoolPriceDifference);
    }

    /// @notice Sets sequencer uptime feed for L2 validation (requires owner privileges)
    /// @dev Configures Chainlink sequencer uptime monitor for L2 networks like Arbitrum/Optimism
    /// @param feed Address of Chainlink sequencer uptime feed (use address(0) to disable for L1)
    function setSequencerUptimeFeed(address feed) external onlyOwner {
        sequencerUptimeFeed = feed;
        emit SetSequencerUptimeFeed(feed);
    }

    /// @notice Gets Chainlink price for a token in reference token terms with caching support
    /// @dev Internal function that calculates relative price between a token and the reference token
    /// @param token Token address to get price for (use address(0) for native ETH)
    /// @param cachedChainlinkReferencePriceX96 Cached price of reference token to avoid redundant Chainlink calls
    /// @return priceX96 Price of token relative to reference token in Q128 format
    /// @return chainlinkReferencePriceX96 Chainlink price of reference token used for calculation
    function _getReferenceTokenPriceX96(address token, uint256 cachedChainlinkReferencePriceX96) internal view returns (uint256 priceX96, uint256 chainlinkReferencePriceX96) {
        if (token == referenceToken) {
            return (Q96, cachedChainlinkReferencePriceX96);
        }

        uint256 chainlinkPriceX96 = _getChainlinkPriceX96(token);
        chainlinkReferencePriceX96 = cachedChainlinkReferencePriceX96 == 0
            ? _getChainlinkPriceX96(referenceToken)
            : cachedChainlinkReferencePriceX96;

        TokenConfig memory feedConfig = feedConfigs[token];

        if (referenceTokenDecimals > feedConfig.tokenDecimals) {
            priceX96 = FullMath.mulDiv(
                (10 ** (referenceTokenDecimals - feedConfig.tokenDecimals)) * chainlinkPriceX96,
                Q96,
                chainlinkReferencePriceX96
            );
        } else if (referenceTokenDecimals < feedConfig.tokenDecimals) {
            priceX96 = chainlinkPriceX96 * Q96 / chainlinkReferencePriceX96
                / (10 ** (feedConfig.tokenDecimals - referenceTokenDecimals));
        } else {
            priceX96 = chainlinkPriceX96 * Q96 / chainlinkReferencePriceX96;
        }
    }

    /// @notice Calculates Chainlink price with validation for given token address
    /// @dev Internal function that fetches Chainlink price with sequencer and stale check validation
    /// @param token Token address to get price for (use address(0) for native ETH)
    /// @return uint256 Chainlink price normalized to Q128 format (decimal adjustment included)
    function _getChainlinkPriceX96(address token) internal view returns (uint256) {
        if (token == chainlinkReferenceToken) {
            return Q96;
        }
        // Sequencer check on chains where needed
        if (sequencerUptimeFeed != address(0)) {
            (, int256 sequencerAnswer, uint256 startedAt,,) =
                AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();

            // Answer == 0: Sequencer is up
            // Answer == 1: Sequencer is down
            if (sequencerAnswer == 1) {
                revert SequencerDown();
            }

            // Feed result must be valid
            if (startedAt == 0) {
                revert SequencerUptimeFeedInvalid();
            }

            // Make sure grace period has passed since sequencer is back up
            uint256 timeSinceUp = block.timestamp - startedAt;
            if (timeSinceUp <= SEQUENCER_GRACE_PERIOD_TIME) {
                revert SequencerGracePeriodNotOver();
            }
        }

        TokenConfig memory feedConfig = feedConfigs[token];
        
        // Check if token is configured
        if (address(feedConfig.feed) == address(0)) {
            revert NotConfigured();
        }

        // Get latest round data from Chainlink
        (, int256 answer,, uint256 updatedAt,) = feedConfig.feed.latestRoundData();
        
        // Check for stale data or invalid price
        if (updatedAt + feedConfig.maxFeedAge < block.timestamp || answer <= 0) {
            revert ChainlinkPriceError();
        }

        return FullMath.mulDiv(SafeCast.toUint256(answer), Q96, 10 ** feedConfig.feedDecimals);
    }

    /// @notice Validates that price difference between two sources doesn't exceed maximum threshold
    /// @dev Internal function that enforces price deviation limits for oracle validation
    /// @param priceX96 First price in Q128 format for comparison
    /// @param verifyPriceX96 Second price in Q128 format for comparison  
    /// @param maxDifferenceX10000 Maximum allowable difference expressed in basis points ×100 (e.g., 1000 = 10%)
    function _requireMaxDifference(uint256 priceX96, uint256 verifyPriceX96, uint16 maxDifferenceX10000) internal pure {

        
        uint256 differenceX10000 =
            priceX96 >= verifyPriceX96 ? (priceX96 - verifyPriceX96) * 10000 : (verifyPriceX96 - priceX96) * 10000;

        // If invalid price or too big difference - revert
        if (
            (verifyPriceX96 == 0 || differenceX10000 / verifyPriceX96 > maxDifferenceX10000)
                && maxDifferenceX10000 < type(uint16).max
        ) {
            revert PriceDifferenceExceeded();
        }
    }

    struct PositionState {
        uint256 tokenId;
        PoolId poolId;
        PoolKey poolKey;
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint160 sqrtPriceX96;
        int24 tick;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint256 price0X96;
        uint256 price1X96;
        uint160 derivedSqrtPriceX96;
        uint256 cachedChainlinkReferencePriceX96;
    }

    /// @notice Loads complete position state and price data from V4 position manager using tokenId
    /// @dev Internal function that consolidates all position data including liquidity, ticks, currencies, and price calculations
    /// @param tokenId Token ID of the position NFT to load state for
    /// @return state Complete PositionState struct containing all position data and calculated prices
    function _loadPositionState(uint256 tokenId) internal view returns (PositionState memory state) {
        
        state.tokenId = tokenId;

        // Get position info from PositionManager
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        
        state.poolId = PoolIdLibrary.toId(poolKey);
        state.poolKey = poolKey;

        // Extract position data
        state.tickLower = PositionInfoLibrary.tickLower(positionInfo);
        state.tickUpper = PositionInfoLibrary.tickUpper(positionInfo);
        
        state.poolId = PoolIdLibrary.toId(poolKey);
        state.currency0 = poolKey.currency0;
        state.currency1 = poolKey.currency1;
        state.fee = poolKey.fee;
        
        // Get basic pool slot0 data (price, tick)
        (state.sqrtPriceX96, state.tick,,) = StateLibrary.getSlot0(poolManager, state.poolId);
        
        // Get price data from chainlink feeds
        (state.price0X96, state.cachedChainlinkReferencePriceX96) = _getReferenceTokenPriceX96(Currency.unwrap(state.currency0), state.cachedChainlinkReferencePriceX96);
        (state.price1X96, ) = _getReferenceTokenPriceX96(Currency.unwrap(state.currency1), state.cachedChainlinkReferencePriceX96);

        // Check derived pool price for manipulation attacks
        uint256 derivedPoolPriceX96 = FullMath.mulDiv(state.price0X96, Q96, state.price1X96);
        
        // Current pool price
        uint256 priceX96 = (uint256(state.sqrtPriceX96) * uint256(state.sqrtPriceX96)) / Q96;
        _requireMaxDifference(priceX96, derivedPoolPriceX96, maxPoolPriceDifference);

        // Calculate derived sqrt price
        state.derivedSqrtPriceX96 = SafeCast.toUint160(Math.sqrt(derivedPoolPriceX96) * (2 ** 48));

        // Get position liquidity and previous fee growth data
        (state.liquidity, state.feeGrowthInside0LastX128, state.feeGrowthInside1LastX128) = StateLibrary.getPositionInfo(
            poolManager, 
            state.poolId, 
            address(positionManager), 
            state.tickLower, 
            state.tickUpper, 
            bytes32(tokenId)
        );
    }

    /// @notice Calculates token amounts of a position based on oracle-derived price
    /// @dev Internal function that converts liquidity to token amounts using oracle price instead of pool price
    /// @param state Complete PositionState struct containing position data and derived price
    /// @return amount0 Calculated amount of token0 based on oracle-derived sqrt price
    /// @return amount1 Calculated amount of token1 based on oracle-derived sqrt price
    function _getAmounts(PositionState memory state) internal pure returns (uint256 amount0, uint256 amount1) {
        if (state.liquidity != 0) {
            // Calculate sqrt prices for tick range using derived price from oracle
            state.sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(state.tickLower);
            state.sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(state.tickUpper);
            
            // Use LiquidityAmounts library to calculate amounts from liquidity
            // Similar to V4Utils._calculateLiquidity but in reverse (amounts from liquidity)
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                state.derivedSqrtPriceX96,    // Current price (from oracle)
                state.sqrtPriceX96Lower,     // Lower tick price
                state.sqrtPriceX96Upper,     // Upper tick price
                state.liquidity              // Position liquidity
            );
        }
    }

    /// @notice Calculates uncollected fees for a V4 position using FullMath precision
    /// @dev Internal function that computes accrued trading fees following Uniswap V4 fee calculation methodology
    /// @param state PositionState
    function _getFees(PositionState memory state
    ) internal view returns (uint128 fees0, uint128 fees1) {

        if (state.liquidity == 0) {
            return (0, 0);
        }
        
        // Get current fee growth inside the position range
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = 
            StateLibrary.getFeeGrowthInside(poolManager, state.poolId, state.tickLower, state.tickUpper);
        
        // Calculate uncollected fees following Uniswap V4 guide
        fees0 = _calculateUncollectedFees(
            feeGrowthInside0X128,
            state.feeGrowthInside0LastX128,
            state.liquidity
        );
        
        fees1 = _calculateUncollectedFees(
            feeGrowthInside1X128,
            state.feeGrowthInside1LastX128,
            state.liquidity
        );
    }
    
    /// @notice Helper function to calculate uncollected fees using FullMath precision math
    /// @dev Internal function that implements the core fee calculation formula: liquidity * (feeGrowth - feeGrowthLast) / Q128
    /// @param feeGrowthInsideX128 Current fee growth accumulator inside the position range (Q128 format)
    /// @param feeGrowthInsideLastX128 Last fee growth accumulator when fees were collected (Q128 format)  
    /// @param liquidity Current liquidity amount in the position
    /// @return uint128 Calculated uncollected fees for this token type
    function _calculateUncollectedFees(
        uint256 feeGrowthInsideX128,
        uint256 feeGrowthInsideLastX128,
        uint128 liquidity
    ) internal pure returns (uint128) {
        if (liquidity == 0) {
            return 0;
        }
        
        uint256 deltaFeeGrowth = feeGrowthInsideX128 - feeGrowthInsideLastX128;
        if (deltaFeeGrowth == 0) {
            return 0;
        }
        
        return uint128(
            FullMath.mulDiv(deltaFeeGrowth, liquidity, FixedPoint128.Q128)
        );
    }
}
