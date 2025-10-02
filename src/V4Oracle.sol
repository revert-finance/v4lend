// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import "@uniswap/v4-core/src/types/PoolId.sol";
import "@uniswap/v4-core/src/types/PoolKey.sol";
import "@uniswap/v4-core/src/interfaces/IHooks.sol";
import "@uniswap/v4-core/src/libraries/TickMath.sol";

import "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import "@uniswap/v4-core/src/libraries/FullMath.sol";
import "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import "./utils/Constants.sol";
import "./interfaces/IV4Oracle.sol";

// Chainlink Price Feed Interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}


/// @title V4Oracle for Uniswap V4 position valuation using Chainlink feeds
/// @notice Simplified oracle that only uses Chainlink feeds (no TWAP) to calculate V4 position values
contract V4Oracle is IV4Oracle, Ownable2Step, Constants {
    uint256 private constant SEQUENCER_GRACE_PERIOD_TIME = 600; // 10mins

    event TokenConfigUpdated(address indexed token, TokenConfig config);
    event SetMaxPoolPriceDifference(uint16 maxPoolPriceDifference);
    event SetEmergencyAdmin(address emergencyAdmin);
    event SetSequencerUptimeFeed(address sequencerUptimeFeed);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    
    // Common token used as reference for price calculations (typically WETH/USDC)
    address public immutable referenceToken;
    uint8 public immutable referenceTokenDecimals;

    // Common token used in Chainlink feeds as "pair" (address(0) if USD reference)
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

    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        address _referenceToken,
        address _chainlinkReferenceToken,
        address _initialOwner
    ) Ownable(_initialOwner) {
        poolManager = _poolManager;
        positionManager = _positionManager;
        referenceToken = _referenceToken;
        referenceTokenDecimals = IERC20Metadata(_referenceToken).decimals();
        chainlinkReferenceToken = _chainlinkReferenceToken;
    }

    /// @notice Gets value and prices of a V4 position in specified token
    /// @param tokenId Token ID of the position NFT
    /// @param token Address of token in which value should be calculated
    /// @return value Value of complete position at oracle prices
    /// @return feeValue Value of position fees only at oracle prices  
    /// @return price0X96 Price of token0 in reference token
    /// @return price1X96 Price of token1 in reference token
    function getValue(uint256 tokenId, address token)
        external
        override
        returns (uint256 value, uint256 feeValue, uint256 price0X96, uint256 price1X96)
    {
        PositionState memory state = _loadPositionState(tokenId);

        (uint256 amount0, uint256 amount1) = _getAmounts(state);
        (uint128 fees0, uint128 fees1) = _getFees(state.poolId, address(positionManager), state.tickLower, state.tickUpper, tokenId);

        // Get price of quote token in reference token
        uint256 priceTokenX96;
        if (state.currency0 == Currency.wrap(token)) {
            priceTokenX96 = state.price0X96;
        } else if (state.currency1 == Currency.wrap(token)) {
            priceTokenX96 = state.price1X96;
        } else {
            priceTokenX96 = _getReferenceTokenPriceX96(token);
        }

        // Calculate outputs
        value = (state.price0X96 * (amount0 + fees0) + state.price1X96 * (amount1 + fees1)) / priceTokenX96;
        feeValue = (state.price0X96 * fees0 + state.price1X96 * fees1) / priceTokenX96;
        price0X96 = state.price0X96 * Q96 / priceTokenX96;
        price1X96 = state.price1X96 * Q96 / priceTokenX96;
    }

    /// @notice Gets breakdown of a V4 position
    /// @param tokenId Token ID of the position NFT
    /// @return currency0 Token0 currency of position
    /// @return currency1 Token1 currency of position  
    /// @return fee Fee tier of position
    /// @return liquidity Liquidity of position
    /// @return amount0 Current amount token0
    /// @return amount1 Current amount token1
    /// @return fees0 Current token0 fees of position
    /// @return fees1 Current token1 fees of position
    function getPositionBreakdown(uint256 tokenId)
        external
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
        // Get position info from PositionManager
        (PoolKey memory poolKey, ) = positionManager.getPoolAndPositionInfo(tokenId);
        
        // Extract basic position data
        currency0 = poolKey.currency0;
        currency1 = poolKey.currency1;
        fee = poolKey.fee;
        
        // Use simplified calculation to avoid stack issues
        (liquidity, fees0, fees1, amount0, amount1) = _getPositionData(tokenId);
    }

    /// @notice Sets or updates the feed configuration for a token (onlyOwner)
    /// @param token Token to configure
    /// @param feed Chainlink feed for this token
    /// @param maxFeedAge Max allowable chainlink feed age in seconds
    function setTokenConfig(
        address token,
        AggregatorV3Interface feed,
        uint32 maxFeedAge
    ) external onlyOwner {
        uint8 feedDecimals = feed.decimals();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();

        TokenConfig memory config = TokenConfig(
            feed,
            maxFeedAge,
            feedDecimals,
            tokenDecimals
        );

        feedConfigs[token] = config;
        emit TokenConfigUpdated(token, config);
    }

    /// @notice Sets the max pool difference parameter (onlyOwner)
    /// @param _maxPoolPriceDifference Set max allowable difference x10000
    function setMaxPoolPriceDifference(uint16 _maxPoolPriceDifference) external onlyOwner {
        maxPoolPriceDifference = _maxPoolPriceDifference;
        emit SetMaxPoolPriceDifference(_maxPoolPriceDifference);
    }

    /// @notice Sets sequencer uptime feed for L2 where needed (onlyOwner)
    /// @param feed Sequencer uptime feed address
    function setSequencerUptimeFeed(address feed) external onlyOwner {
        sequencerUptimeFeed = feed;
        emit SetSequencerUptimeFeed(feed);
    }

    /// @notice Gets Chainlink price for a token in reference token terms
    function _getReferenceTokenPriceX96(address token) internal view returns (uint256) {
        if (token == referenceToken) {
            return Q96;
        }

        return _getChainlinkPriceX96(token);
    }

    /// @notice Calculates Chainlink price given token addresses
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

        return uint256(answer) * Q96 / (10 ** feedConfig.feedDecimals);
    }

    /// @notice Requires that price difference doesn't exceed maximum
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
        PoolId poolId;
        PoolKey poolKey;
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        int24 tick;
        uint160 sqrtPriceX96Lower;
        uint160 sqrtPriceX96Upper;
        uint256 price0X96;
        uint256 price1X96;
        uint160 derivedSqrtPriceX96;
        uint256 cachedChainlinkReferencePriceX96;
    }

    /// @notice Loads position state from V4 position manager using tokenId
    function _loadPositionState(uint256 tokenId) internal view returns (PositionState memory state) {
        // Get position info from PositionManager
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        
        state.poolKey = poolKey;

        // Extract position data
        state.tickLower = PositionInfoLibrary.tickLower(positionInfo);
        state.tickUpper = PositionInfoLibrary.tickUpper(positionInfo);
        
        // Convert PoolKey to PoolId
        state.poolId = PoolIdLibrary.toId(poolKey);
        
        state.poolId = PoolIdLibrary.toId(poolKey);
        state.currency0 = poolKey.currency0;
        state.currency1 = poolKey.currency1;
        state.fee = poolKey.fee;
        
        // Get basic pool slot0 data (price, tick)
        (state.sqrtPriceX96, state.tick,,) = StateLibrary.getSlot0(poolManager, state.poolId);
        
        // Get position liquidity
        state.liquidity = _getPositionLiquidity(state.poolId, address(positionManager), state.tickLower, state.tickUpper, tokenId);
    
        // Get price data from chainlink feeds
        state.price0X96 = _getReferenceTokenPriceX96(Currency.unwrap(state.currency0));
        state.price1X96 = _getReferenceTokenPriceX96(Currency.unwrap(state.currency1));

        // Check derived pool price for manipulation attacks
        uint256 derivedPoolPriceX96 = state.price0X96 * Q96 / state.price1X96;
        
        // Current pool price
        uint256 priceX96 = (uint256(state.sqrtPriceX96) * uint256(state.sqrtPriceX96)) / Q96;
        _requireMaxDifference(priceX96, derivedPoolPriceX96, maxPoolPriceDifference);

        // Calculate derived sqrt price
        state.derivedSqrtPriceX96 = SafeCast.toUint160(Math.sqrt(derivedPoolPriceX96) * (2 ** 48));
    }


    /// @notice Calculate position amounts given derived price from oracle
    function _getAmounts(PositionState memory state) internal pure returns (uint256 amount0, uint256 amount1) {
        if (state.liquidity != 0) {
            // Calculate sqrt prices for tick range using derived price from oracle
            state.sqrtPriceX96Lower = TickMath.getSqrtPriceAtTick(state.tickLower);
            state.sqrtPriceX96Upper = TickMath.getSqrtPriceAtTick(state.tickUpper);
            
            // Use LiquidityAmounts library to calculate amounts from liquidity
            // Similar to V4Utils._calculateLiquidity but in reverse (amounts from liquidity)
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                state.derivedSqrtPriceX96,  // Current price (from oracle)
                state.sqrtPriceX96Lower,     // Lower tick price
                state.sqrtPriceX96Upper,     // Upper tick price
                state.liquidity              // Position liquidity
            );
        }
    }

    /// @notice Calculate uncollected position fees for V4
    /// @param poolId Pool ID of the position
    /// @param owner Owner address (position manager)
    /// @param tickLower Lower tick of position
    /// @param tickUpper Upper tick of position
    /// @param salt Salt (tokenId) for the position
    /// @return fees0 Uncollected fees in token0
    /// @return fees1 Uncollected fees in token1
    function _getFees(
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 salt
    ) internal view returns (uint128 fees0, uint128 fees1) {
        // Get position liquidity and previous fee growth data
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = 
            _getPositionInfo(poolId, owner, tickLower, tickUpper, salt);
        
        if (liquidity == 0) {
            return (0, 0);
        }
        
        // Get current fee growth inside the position range
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = 
            StateLibrary.getFeeGrowthInside(poolManager, poolId, tickLower, tickUpper);
        
        // Calculate uncollected fees following Uniswap V4 guide
        fees0 = _calculateUncollectedFees(
            feeGrowthInside0X128,
            feeGrowthInside0LastX128,
            liquidity
        );
        
        fees1 = _calculateUncollectedFees(
            feeGrowthInside1X128,
            feeGrowthInside1LastX128,
            liquidity
        );
    }

    /// @notice Gets liquidity and uncollected fees for a position by tokenId (V4-specific)
    /// @param tokenId Token ID of the position NFT
    /// @return liquidity Liquidity of position
    /// @return fees0 Current token0 fees of position
    /// @return fees1 Current token1 fees of position
    function getLiquidityAndFees(uint256 tokenId)
        external
        view
        override
        returns (uint128 liquidity, uint128 fees0, uint128 fees1)
    {
        PositionState memory state = _loadPositionState(tokenId);


        // Get position liquidity
        liquidity = state.liquidity;
        
        // Get uncollected fees using the refactored helper method
        (fees0, fees1) = _getFees(state.poolId, address(positionManager), state.tickLower, state.tickUpper, tokenId);
    }
    
    /// @notice Helper function to get position data while avoiding stack too deep
    function _getPositionData(uint256 tokenId) internal returns (uint128 liquidity, uint128 fees0, uint128 fees1, uint256 amount0, uint256 amount1) {
        PositionState memory state = _loadPositionState(tokenId);
        (amount0, amount1) = _getAmounts(state);
        (fees0, fees1) = _getFees(state.poolId, address(positionManager), state.tickLower, state.tickUpper, tokenId);
        liquidity = state.liquidity;
    }
    
    /// @notice Helper function to get position liquidity and fee growth data
    function _getPositionFeeGrowth(
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 salt
    ) internal view returns (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) {
        (, feeGrowthInside0LastX128, feeGrowthInside1LastX128) = StateLibrary.getPositionInfo(
            poolManager, 
            poolId, 
            owner, 
            tickLower, 
            tickUpper, 
            bytes32(salt)
        );
    }
    
    /// @notice Helper function to get complete position info in one call
    function _getPositionInfo(
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 salt
    ) internal view returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) {
        (liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128) = StateLibrary.getPositionInfo(
            poolManager, 
            poolId, 
            owner, 
            tickLower, 
            tickUpper, 
            bytes32(salt)
        );
    }
    
    /// @notice Helper function to get position liquidity
    function _getPositionLiquidity(
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint256 salt
    ) internal view returns (uint128) {
        (uint128 liquidity,,) = StateLibrary.getPositionInfo(
            poolManager, 
            poolId, 
            owner, 
            tickLower, 
            tickUpper, 
            bytes32(salt)
        );
        return liquidity;
    }
    
    /// @notice Helper function to calculate uncollected fees using FullMath
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
