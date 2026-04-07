// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Multicall} from "@openzeppelin/contracts/utils/Multicall.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IVault} from "./interfaces/IVault.sol";
import {IV4Oracle} from "../oracle/interfaces/IV4Oracle.sol";
import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {Constants} from "../shared/Constants.sol";

/// @title Revert Lend Vault for token lending / borrowing using Uniswap V4 LP positions as collateral
/// @notice The vault manages ONE ERC20 (eg. USDC) asset for lending / borrowing, but collateral positions can be composed of any 2 tokens configured each with a collateralFactor > 0
/// @dev Vault implements IERC4626 Vault Standard and is itself an ERC20 which represents shares of the total lending pool
/// @custom:security Trust Assumptions:
///   - Owner is trusted to configure valid token collateral factors and transformers
///   - Oracle is trusted to provide accurate position valuations
///   - Transformers are whitelisted and audited contracts that can modify positions atomically
///   - Interest rate model is trusted for rate calculations
/// @custom:security Reentrancy:
///   - transform() is protected by transformedTokenId state variable acting as a reentrancy guard
///   - liquidate() and borrow() check transformedTokenId to prevent reentrancy
/// @custom:security Oracle Manipulation:
///   - Position values depend on V4Oracle which validates pool prices against Chainlink feeds
///   - Price manipulation attacks are mitigated by maxPoolPriceDifference check
contract V4Vault is ERC20, Multicall, Ownable2Step, IVault, IERC721Receiver, Constants {
    using Math for uint256;

    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 public constant MAX_COLLATERAL_FACTOR_X32 = uint32(Q32 * 90 / 100); // 90%

    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 public constant MIN_LIQUIDATION_PENALTY_X32 = uint32(Q32 * 2 / 100); // 2%
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 public constant MAX_LIQUIDATION_PENALTY_X32 = uint32(Q32 * 10 / 100); // 10%

    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 public constant MIN_RESERVE_PROTECTION_FACTOR_X32 = uint32(Q32 / 100); //1%

    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 public constant MAX_DAILY_LEND_INCREASE_X32 = uint32(Q32 / 10); //10%
    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 public constant MAX_DAILY_DEBT_INCREASE_X32 = uint32(Q32 / 10); //10%

    /// @notice Uniswap v4 position manager
    IPositionManager public immutable positionManager;

    /// @notice Uniswap v4 pool manager
    IPoolManager public immutable poolManager;

    /// @notice interest rate model implementation
    IInterestRateModel public immutable interestRateModel;

    /// @notice oracle implementation
    IV4Oracle public immutable oracle;
 
    /// @notice wrapped native token address
    IWETH9 public immutable weth;

    /// @notice underlying asset for lending / borrowing
    address public immutable override asset;

    /// @notice decimals of underlying token (are the same as ERC20 share token)
    uint8 private immutable assetDecimals;

    // events
    event ApprovedTransform(uint256 indexed tokenId, address owner, address target, bool isActive);

    event Add(uint256 indexed tokenId, address owner, uint256 oldTokenId); // when a token is added replacing another token - oldTokenId > 0
    event Remove(uint256 indexed tokenId, address owner, address recipient);
    event Transfer(uint256 indexed tokenId, address from, address to);

    event ExchangeRateUpdate(uint256 debtExchangeRateX96, uint256 lendExchangeRateX96);
    // Deposit and Withdraw events are defined in IERC4626
    event WithdrawCollateral(
        uint256 indexed tokenId, address owner, address recipient, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event Borrow(uint256 indexed tokenId, address owner, uint256 assets, uint256 shares);
    event Repay(uint256 indexed tokenId, address repayer, address owner, uint256 assets, uint256 shares);
    event Liquidate(
        uint256 indexed tokenId,
        address liquidator,
        address owner,
        uint256 value,
        uint256 cost,
        uint256 amount0,
        uint256 amount1,
        uint256 reserve,
        uint256 missing
    ); // shows exactly how liquidation amounts were divided

    // admin events
    event WithdrawReserves(uint256 amount, address receiver);
    event SetTransformer(address transformer, bool active);
    event SetLimits(
        uint256 minLoanSize,
        uint256 globalLendLimit,
        uint256 globalDebtLimit,
        uint256 dailyLendIncreaseLimitMin,
        uint256 dailyDebtIncreaseLimitMin
    );
    event SetReserveFactor(uint32 reserveFactorX32);
    event SetReserveProtectionFactor(uint32 reserveProtectionFactorX32);
    event SetTokenConfig(address token, uint32 collateralFactorX32, uint32 collateralValueLimitFactorX32);

    event SetEmergencyAdmin(address emergencyAdmin);
    event SetHookAllowList(address hook, bool isAllowed);

    // configured tokens
    struct TokenConfig {
        uint32 collateralFactorX32; // how much this token is valued as collateral
        uint32 collateralValueLimitFactorX32; // how much asset equivalent may be lent out given this collateral
        uint192 totalDebtShares; // how much debt shares are theoretically backed by this collateral
    }

    mapping(address => TokenConfig) public tokenConfigs;

    // hooks which are allowed in positions
    mapping(address => bool) public hookAllowList;

    // total of debt shares - increases when borrow - decreases when repay
    uint256 public debtSharesTotal;

    // exchange rates are Q96 at the beginning - 1 share token per 1 asset token
    uint256 public lastDebtExchangeRateX96 = Q96;
    uint256 public lastLendExchangeRateX96 = Q96;

    uint256 public globalDebtLimit;
    uint256 public globalLendLimit;

    // minimal size of loan (to protect from non-liquidatable positions because of gas-cost)
    uint256 public minLoanSize;

    // daily lend increase limit handling
    uint256 public dailyLendIncreaseLimitMin;
    uint256 public dailyLendIncreaseLimitLeft;

    // daily debt increase limit handling
    uint256 public dailyDebtIncreaseLimitMin;
    uint256 public dailyDebtIncreaseLimitLeft;

    // lender balances are handled with ERC-20 mint/burn

    // loans are handled with this struct
    struct Loan {
        uint256 debtShares;
    }

    mapping(uint256 => Loan) public override loans; // tokenID -> loan mapping

    // storage variables to handle enumerable token ownership
    mapping(address => uint256[]) private ownedTokens; // Mapping from owner address to list of owned token IDs
    mapping(uint256 => uint256) private ownedTokensIndex; // Mapping from token ID to index of the owner tokens list (for removal without loop)
    mapping(uint256 => address) private tokenOwner; // Mapping from token ID to owner

    uint256 public override transformedTokenId; // stores currently transformed token (is always reset to 0 after tx)

    mapping(address => bool) public transformerAllowList; // contracts allowed to transform positions (selected audited contracts e.g. V4Utils)
    mapping(address => mapping(uint256 => mapping(address => bool))) public transformApprovals; // owners permissions for other addresses to call transform on owners behalf (e.g. AutoRange contract)

    // last time exchange rate was updated
    uint64 public lastExchangeRateUpdate;

    // percentage of interest which is kept in the protocol for reserves
    uint32 public reserveFactorX32;

    // percentage of lend amount which needs to be in reserves before withdrawn
    uint32 public reserveProtectionFactorX32 = MIN_RESERVE_PROTECTION_FACTOR_X32;

    // when limits where last reset
    uint32 public dailyLendIncreaseLimitLastReset;
    uint32 public dailyDebtIncreaseLimitLastReset;

    // address which can call special emergency actions without timelock
    address public emergencyAdmin;

    constructor(
        string memory name,
        string memory symbol,
        address _asset,
        IPositionManager _positionManager,
        IInterestRateModel _interestRateModel,
        IV4Oracle _oracle,
        IWETH9 _weth
    ) ERC20(name, symbol) Ownable(msg.sender) {
        asset = _asset;
        assetDecimals = IERC20Metadata(_asset).decimals();
        positionManager = _positionManager;
        poolManager = IPoolManager(_positionManager.poolManager());
        interestRateModel = _interestRateModel;
        oracle = _oracle;
        weth = _weth;
    }

    ////////////////// EXTERNAL VIEW FUNCTIONS

    /// @notice Retrieves global information about the vault
    /// @return debt Total amount of debt asset tokens
    /// @return lent Total amount of lent asset tokens
    /// @return balance Balance of asset token in contract
    /// @return reserves Amount of reserves
    function vaultInfo()
        external
        view
        override
        returns (
            uint256 debt,
            uint256 lent,
            uint256 balance,
            uint256 reserves,
            uint256 debtExchangeRateX96,
            uint256 lendExchangeRateX96
        )
    {
        (debtExchangeRateX96, lendExchangeRateX96) = _calculateGlobalInterest();
        (balance, reserves) = _getBalanceAndReserves(debtExchangeRateX96, lendExchangeRateX96);

        debt = _convertToAssets(debtSharesTotal, debtExchangeRateX96, Math.Rounding.Ceil);
        lent = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Floor);
    }

    /// @notice Retrieves lending information for a specified account.
    /// @param account The address of the account for which lending info is requested.
    /// @return amount Amount of lent assets for the account
    function lendInfo(address account) external view override returns (uint256 amount) {
        (, uint256 newLendExchangeRateX96) = _calculateGlobalInterest();
        amount = _convertToAssets(balanceOf(account), newLendExchangeRateX96, Math.Rounding.Floor);
    }

    /// @notice Retrieves details of a loan identified by its token ID.
    /// @param tokenId The unique identifier of the loan - which is the corresponding UniV4 Position
    /// @return debt Amount of debt for this position
    /// @return fullValue Current value of the position priced as asset token
    /// @return collateralValue Current collateral value of the position priced as asset token
    /// @return liquidationCost If position is liquidatable - cost to liquidate position - otherwise 0
    /// @return liquidationValue If position is liquidatable - the value of the (partial) position which the liquidator recieves - otherwise 0
    /// @dev Requires Oracle support for both position tokens and the vault asset token.
    ///      If a required token feed is missing, oracle.getValue() reverts with NotConfigured().
    function loanInfo(uint256 tokenId)
        external
        view
        override
        returns (
            uint256 debt,
            uint256 fullValue,
            uint256 collateralValue,
            uint256 liquidationCost,
            uint256 liquidationValue
        )
    {
        (uint256 newDebtExchangeRateX96,) = _calculateGlobalInterest();

        debt = _convertToAssets(loans[tokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Ceil);

        bool isHealthy;
        (isHealthy, fullValue, collateralValue,) = _checkLoanIsHealthy(tokenId, debt);

        if (!isHealthy) {
            (liquidationValue, liquidationCost,) = _calculateLiquidation(debt, fullValue, collateralValue);
        }
    }

    /// @notice Retrieves owner of a loan
    /// @param tokenId The unique identifier of the loan - which is the corresponding UniV4 Position
    /// @return owner Owner of the loan
    function ownerOf(uint256 tokenId) external view override returns (address owner) {
        return tokenOwner[tokenId];
    }

    /// @notice Retrieves count of loans for owner (for enumerating owners loans)
    /// @param owner Owner address
    function loanCount(address owner) external view override returns (uint256) {
        return ownedTokens[owner].length;
    }

    /// @notice Retrieves tokenid of loan at given index for owner (for enumerating owners loans)
    /// @param owner Owner address
    /// @param index Index
    function loanAtIndex(address owner, uint256 index) external view override returns (uint256) {
        return ownedTokens[owner][index];
    }

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC20
    /// @inheritdoc IERC20Metadata
    function decimals() public view override(IERC20Metadata, ERC20) returns (uint8) {
        return assetDecimals;
    }

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC4626

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) external view override returns (uint256 shares) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) external view override returns (uint256 assets) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 value = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Ceil);
        if (value >= globalLendLimit) {
            return 0;
        } else {
            uint256 maxGlobalDeposit = globalLendLimit - value;
            if (maxGlobalDeposit > dailyLendIncreaseLimitLeft) {
                return dailyLendIncreaseLimitLeft;
            } else {
                return maxGlobalDeposit;
            }
        }
    }

    /// @inheritdoc IERC4626
    function maxMint(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 value = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Ceil);
        if (value >= globalLendLimit) {
            return 0;
        } else {
            uint256 maxGlobalDeposit = globalLendLimit - value;
            if (maxGlobalDeposit > dailyLendIncreaseLimitLeft) {
                return _convertToShares(dailyLendIncreaseLimitLeft, lendExchangeRateX96, Math.Rounding.Floor);
            } else {
                return _convertToShares(maxGlobalDeposit, lendExchangeRateX96, Math.Rounding.Floor);
            }
        }
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) external view override returns (uint256) {
        (uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) = _calculateGlobalInterest();

        uint256 ownerShareBalance = balanceOf(owner);
        uint256 ownerAssetBalance = _convertToAssets(ownerShareBalance, lendExchangeRateX96, Math.Rounding.Floor);

        (uint256 balance,) = _getBalanceAndReserves(debtExchangeRateX96, lendExchangeRateX96);
        if (balance > ownerAssetBalance) {
            return ownerAssetBalance;
        } else {
            return balance;
        }
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) external view override returns (uint256) {
        (uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) = _calculateGlobalInterest();

        uint256 ownerShareBalance = balanceOf(owner);

        (uint256 balance,) = _getBalanceAndReserves(debtExchangeRateX96, lendExchangeRateX96);
        uint256 shareBalance = _convertToShares(balance, lendExchangeRateX96, Math.Rounding.Floor);

        if (shareBalance > ownerShareBalance) {
            return ownerShareBalance;
        } else {
            return shareBalance;
        }
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Floor);
    }

    ////////////////// OVERRIDDEN EXTERNAL FUNCTIONS FROM ERC4626

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) external override returns (uint256) {
        (, uint256 shares) = _deposit(receiver, assets, false);
        return shares;
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) external override returns (uint256) {
        (uint256 assets,) = _deposit(receiver, shares, true);
        return assets;
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256) {
        (, uint256 shares) = _withdraw(receiver, owner, assets, false);
        return shares;
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256) {
        (uint256 assets,) = _withdraw(receiver, owner, shares, true);
        return assets;
    }

    ////////////////// EXTERNAL FUNCTIONS

    /// @notice Creates a new collateralized position by transferring an approved Uniswap V4 position NFT
    /// @dev The position NFT must be approved for this contract. The recipient becomes the loan owner.
    /// @param tokenId The token ID of the Uniswap V4 position NFT to use as collateral
    /// @param recipient Address to receive ownership of the position/loan in the vault
    /// @custom:security The hook attached to the position must be in hookAllowList or be address(0)
    function create(uint256 tokenId, address recipient) external override {
        IERC721(address(positionManager)).safeTransferFrom(msg.sender, address(this), tokenId, abi.encode(recipient));
    }

    /// @notice Handles special case when a token is received by the vault from a hook contract during transform
    /// @dev Can only be called by whitelisted transformers while in transform mode. Used when hooks create new positions.
    /// @param tokenId The token ID of the newly received position NFT
    /// @param recipient Address to receive ownership of the position/loan
    /// @custom:security Only callable from transformer contracts during active transform to prevent unauthorized position injection
    function notifyERC721Received(uint256 tokenId, address recipient) external override {

        // must be called from a transformer contract, be in transform mode and the token must not be owned by anyone else
        if (!transformerAllowList[msg.sender] || transformedTokenId == 0 || tokenOwner[tokenId] != address(0)) {
            revert Unauthorized();
        }

        _handleErc721Received(tokenId, recipient);
    }

    /// @notice Whenever a token is recieved it either creates a new loan, or modifies an existing one when in transform mode.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, /*operator*/ address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        // only Uniswap v4 NFTs allowed - sent from other contract
        if (msg.sender != address(positionManager) || from == address(this)) {
            revert WrongContract();
        }

        address owner = from;
        if (data.length != 0) {
            owner = abi.decode(data, (address));
        }

        _handleErc721Received(tokenId, owner);

        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Internal function to handle ERC721 token receipt logic
    /// @param tokenId The token ID received
    /// @param owner The owner address for the new loan
    function _handleErc721Received(uint256 tokenId, address owner) internal {
        (uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) = _updateGlobalInterest();

        uint256 oldTokenId = transformedTokenId;

        if (oldTokenId == 0) {
            loans[tokenId] = Loan(0);

            _checkHookAllowed(tokenId);
            _addTokenToOwner(owner, tokenId);
            emit Add(tokenId, owner, 0);
        } else {
            // if in transform mode - and a new position is sent - current position is replaced and returned
            if (tokenId != oldTokenId) {

                address owner_ = tokenOwner[oldTokenId];

                // set transformed token to new one
                transformedTokenId = tokenId;

                uint256 debtShares = loans[oldTokenId].debtShares;

                // copy debt to new token
                loans[tokenId] = Loan(debtShares);

                _checkHookAllowed(tokenId);
                _addTokenToOwner(owner_, tokenId);
                emit Add(tokenId, owner_, oldTokenId);

                // remove debt from old loan
                _cleanupLoan(oldTokenId, debtExchangeRateX96, lendExchangeRateX96);

                // sets data of new loan
                _updateAndCheckCollateral(
                    tokenId, debtExchangeRateX96, lendExchangeRateX96, 0, debtShares
                );
            }
        }
    }

    /// @notice Allows another address to call transform on behalf of owner (on a given token)
    /// @param tokenId The token to be permitted
    /// @param target The address to be allowed
    /// @param isActive If it allowed or not
    function approveTransform(uint256 tokenId, address target, bool isActive) external override {
        if (tokenOwner[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        transformApprovals[msg.sender][tokenId][target] = isActive;

        emit ApprovedTransform(tokenId, msg.sender, target, isActive);
    }

    /// @notice Transfers ownership of a loan to a new owner
    /// @param tokenId The token ID of the loan to transfer
    /// @param newOwner The address of the new owner
    function transferLoan(uint256 tokenId, address newOwner) external override {

        // transferLoan is not allowed during transformer mode
        if (transformedTokenId != 0) {
            revert TransformNotAllowed();
        }

        address currentOwner = tokenOwner[tokenId];
        if (currentOwner != msg.sender) {
            revert Unauthorized();
        }
        if (newOwner == address(0)) {
            revert Unauthorized();
        }

        _removeTokenFromOwner(currentOwner, tokenId);
        _addTokenToOwner(newOwner, tokenId);

        emit Transfer(tokenId, currentOwner, newOwner);
    }

    /// @notice Allows a whitelisted transformer contract to atomically modify a loan position
    /// @dev The transformer pattern enables complex operations (range changes, leverage, etc.) while ensuring
    ///      collateral health is verified only after all modifications complete.
    /// @param tokenId The token ID of the position to transform
    /// @param transformer The address of a whitelisted transformer contract (must be in transformerAllowList)
    /// @param data Encoded function call data to execute on the transformer
    /// @return newTokenId Final token ID (may differ from input if position was replaced during transformation)
    /// @custom:security Reentrancy Protection: Uses transformedTokenId as mutex - reverts if already in transform
    /// @custom:security Trust Model: Transformers are whitelisted by owner and can call borrow() during transform
    /// @custom:security After transform completes, loan health is verified to ensure sufficient collateralization
    function transform(uint256 tokenId, address transformer, bytes calldata data)
        external
        override
        returns (uint256 newTokenId)
    {
        if (tokenId == 0 || !transformerAllowList[transformer]) {
            revert TransformNotAllowed();
        }
        if (transformedTokenId != 0) {
            revert Reentrancy();
        }
        transformedTokenId = tokenId;

        (uint256 newDebtExchangeRateX96,) = _updateGlobalInterest();

        address loanOwner = tokenOwner[tokenId];

        // only the owner of the loan or any approved caller can call this
        if (loanOwner != msg.sender && !transformApprovals[loanOwner][tokenId][msg.sender]) {
            revert Unauthorized();
        }

        // give access to transformer
        IERC721(address(positionManager)).approve(transformer, tokenId);

        (bool success,) = transformer.call(data);
        if (!success) {
            revert TransformFailed();
        }

        // may have changed in the meantime
        newTokenId = transformedTokenId;

        // if token has changed - and operator was approved for old token - take over for new token
        if (tokenId != newTokenId && transformApprovals[loanOwner][tokenId][msg.sender]) {
            transformApprovals[loanOwner][newTokenId][msg.sender] = true;
        }

        // check owner not changed (NEEDED because token could have been moved somewhere else in the meantime)
        address owner = IERC721(address(positionManager)).ownerOf(newTokenId);
        if (owner != address(this)) {
            revert Unauthorized();
        }

        // remove access for transformer
        IERC721(address(positionManager)).approve(address(0), newTokenId);

        uint256 debt = _convertToAssets(loans[newTokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Ceil);
        _requireLoanIsHealthy(newTokenId, debt);

        transformedTokenId = 0;
    }

    /// @notice Borrows specified amount of the vault's asset using the position as collateral
    /// @dev Can be called by position owner directly, or by transformers during transform mode.
    ///      Checks global debt limits, daily limits, minimum loan size, and collateral health.
    ///      Practical requirement: both position tokens must be configured in setTokenConfig(),
    ///      and oracle feeds must exist for both position tokens plus the vault asset.
    /// @param tokenId The token ID of the position to use as collateral
    /// @param assets Amount of assets to borrow (in asset token decimals)
    /// @custom:security Validates sufficient collateralization after borrow
    /// @custom:security In transform mode, health check is deferred to end of transform()
    function borrow(uint256 tokenId, uint256 assets) external override {

        bool isTransformMode = tokenId != 0 && transformedTokenId == tokenId && transformerAllowList[msg.sender];

        address owner = tokenOwner[tokenId];

        // if not in transform mode - must be called from owner
        if (!isTransformMode && owner != msg.sender) {
            revert Unauthorized();
        }

        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, false);

        Loan storage loan = loans[tokenId];

        uint256 shares = _convertToShares(assets, newDebtExchangeRateX96, Math.Rounding.Ceil);

        uint256 loanDebtShares = loan.debtShares + shares;
        loan.debtShares = loanDebtShares;
        debtSharesTotal = debtSharesTotal + shares;

        if (debtSharesTotal > _convertToShares(globalDebtLimit, newDebtExchangeRateX96, Math.Rounding.Floor)) {
            revert GlobalDebtLimit();
        }
        if (assets > dailyDebtIncreaseLimitLeft) {
            revert DailyDebtIncreaseLimit();
        } else {
            dailyDebtIncreaseLimitLeft = dailyDebtIncreaseLimitLeft - assets;
        }

        _updateAndCheckCollateral(
            tokenId, newDebtExchangeRateX96, newLendExchangeRateX96, loanDebtShares - shares, loanDebtShares
        );

        uint256 debt = _convertToAssets(loanDebtShares, newDebtExchangeRateX96, Math.Rounding.Ceil);

        if (debt < minLoanSize) {
            revert MinLoanSize();
        }

        // only does check health here if not in transform mode
        if (!isTransformMode) {
            _requireLoanIsHealthy(tokenId, debt);
        }

        // fails if not enough asset available
        // it may use all balance of the contract (because "virtual" reserves do not need to be stored in contract)
        // if called from transform mode - send funds to transformer contract
        SafeERC20.safeTransfer(IERC20(asset), msg.sender, assets);

        emit Borrow(tokenId, owner, assets, shares);
    }

    /// @dev Decreases the liquidity of a given position and collects the resultant assets (and possibly additional fees)
    /// This function is not allowed during transformation (if a transformer wants to decreaseLiquidity he can call the methods directly on the PositionManager)
    /// @param params Struct containing various parameters for the operation. Includes tokenId, liquidity amount, minimum asset amounts, and deadline.
    /// @return amount0 The amount of the first type of asset collected.
    /// @return amount1 The amount of the second type of asset collected.
    function decreaseLiquidityAndCollect(DecreaseLiquidityAndCollectParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        // this method is not allowed during transform - can be called directly on positionManager if needed from transform contract
        if (transformedTokenId != 0) {
            revert TransformNotAllowed();
        }

        address owner = tokenOwner[params.tokenId];

        if (owner != msg.sender) {
            revert Unauthorized();
        }

        (uint256 newDebtExchangeRateX96,) = _updateGlobalInterest();

        (amount0, amount1) = _decreaseLiquidity(
            params.tokenId,
            params.liquidity,
            params.amount0Min,
            params.amount1Min,
            params.deadline,
            params.decreaseLiquidityHookData,
            params.recipient
        );

        uint256 debt = _convertToAssets(loans[params.tokenId].debtShares, newDebtExchangeRateX96, Math.Rounding.Ceil);
        _requireLoanIsHealthy(params.tokenId, debt);

        emit WithdrawCollateral(params.tokenId, owner, params.recipient, params.liquidity, amount0, amount1);
    }

    /// @notice Repays borrowed tokens. Can be denominated in assets or debt share amount
    /// @param tokenId The token ID to use as collateral
    /// @param amount How many assets/debt shares to repay
    /// @param isShare Is amount specified in assets or debt shares.
    /// @return assets The amount of the assets repayed
    /// @return shares The amount of the shares repayed
    function repay(uint256 tokenId, uint256 amount, bool isShare)
        external
        override
        returns (uint256 assets, uint256 shares)
    {
        (assets, shares) = _repay(tokenId, amount, isShare);
    }

    // state used in liquidation function to avoid stack too deep errors
    struct LiquidateState {
        uint256 newDebtExchangeRateX96;
        uint256 newLendExchangeRateX96;
        uint256 debt;
        bool isHealthy;
        uint256 liquidationValue;
        uint256 liquidatorCost;
        uint256 reserveCost;
        uint256 missing;
        uint256 fullValue;
        uint256 collateralValue;
        uint256 feeValue;
    }

    /// @notice Liquidates an unhealthy position by repaying debt and receiving collateral
    /// @dev Liquidation penalty ranges from 2% to 10% based on position health.
    ///      If position value < debt + max penalty, shortfall is covered by reserves then lenders.
    /// @param params LiquidateParams struct containing tokenId, min amounts, deadline, and hook data
    /// @return amount0 Amount of token0 received by liquidator
    /// @return amount1 Amount of token1 received by liquidator
    /// @custom:security Not callable during transform mode to prevent manipulation
    /// @custom:security Liquidator must approve sufficient assets before calling
    /// @custom:security Penalty calculation: linear interpolation from 2% (just liquidatable) to 10% (fully underwater)
    function liquidate(LiquidateParams calldata params) external override returns (uint256 amount0, uint256 amount1) {
        // liquidation is not allowed during transformer mode
        if (transformedTokenId != 0) {
            revert TransformNotAllowed();
        }

        LiquidateState memory state;

        (state.newDebtExchangeRateX96, state.newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyDebtIncreaseLimit(state.newLendExchangeRateX96, false);

        uint256 debtShares = loans[params.tokenId].debtShares;

        state.debt = _convertToAssets(debtShares, state.newDebtExchangeRateX96, Math.Rounding.Ceil);

        (state.isHealthy, state.fullValue, state.collateralValue, state.feeValue) =
            _checkLoanIsHealthy(params.tokenId, state.debt);
        if (state.isHealthy) {
            revert NotLiquidatable();
        }

        (state.liquidationValue, state.liquidatorCost, state.reserveCost) =
            _calculateLiquidation(state.debt, state.fullValue, state.collateralValue);

        // calculate reserve (before transfering liquidation money - otherwise calculation is off)
        if (state.reserveCost > 0) {
            state.missing =
                _handleReserveLiquidation(state.reserveCost, state.newDebtExchangeRateX96, state.newLendExchangeRateX96);
        }

        if (state.liquidatorCost > 0) {
            // take value from liquidator
            SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), state.liquidatorCost);
        }

        debtSharesTotal = debtSharesTotal - debtShares;

        dailyDebtIncreaseLimitLeft = dailyDebtIncreaseLimitLeft + state.debt;

        // send promised collateral tokens to liquidator
        (amount0, amount1) = _sendPositionValue(
            params, state.liquidationValue, state.fullValue, state.feeValue
        );

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert SlippageError();
        }

        // remove debt from loan
        _cleanupLoan(params.tokenId, state.newDebtExchangeRateX96, state.newLendExchangeRateX96);

        emit Liquidate(
            params.tokenId,
            msg.sender,
            tokenOwner[params.tokenId],
            state.fullValue,
            state.liquidatorCost,
            amount0,
            amount1,
            state.reserveCost,
            state.missing
        );
    }

    /// @notice Removes position from the vault (only possible when all repayed)
    /// @param tokenId The token ID to use as collateral
    /// @param recipient Address to recieve NFT
    /// @param data Optional data to send to reciever
    function remove(uint256 tokenId, address recipient, bytes calldata data) external {
        address owner = tokenOwner[tokenId];
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        if (loans[tokenId].debtShares > 0) {
            revert NeedsRepay();
        }

        _removeTokenFromOwner(owner, tokenId);
        IERC721(address(positionManager)).safeTransferFrom(address(this), recipient, tokenId, data);
        emit Remove(tokenId, owner, recipient);
    }

    ////////////////// ADMIN FUNCTIONS only callable by owner

    /// @notice Withdraws protocol reserves accumulated from interest spread (onlyOwner)
    /// @dev Only allows withdrawing reserves above the protection threshold (globalLendAmount * reserveProtectionFactor).
    ///      This ensures minimum reserves are always maintained to absorb potential bad debt.
    /// @param amount Amount of reserves to withdraw
    /// @param receiver Address to receive the withdrawn reserves
    /// @custom:security Protected by reserveProtectionFactor to maintain solvency buffer
    function withdrawReserves(uint256 amount, address receiver) external onlyOwner {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        uint256 protected =
            _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Ceil) * reserveProtectionFactorX32 / Q32;
        (uint256 balance, uint256 reserves) = _getBalanceAndReserves(newDebtExchangeRateX96, newLendExchangeRateX96);
        uint256 unprotected = reserves > protected ? reserves - protected : 0;
        uint256 available = balance > unprotected ? unprotected : balance;

        if (amount > available) {
            revert InsufficientLiquidity();
        }

        if (amount > 0) {
            SafeERC20.safeTransfer(IERC20(asset), receiver, amount);
        }

        emit WithdrawReserves(amount, receiver);
    }

    /// @notice Configures whether a contract is allowed to act as a transformer (onlyOwner)
    /// @dev Transformers can call transform() to atomically modify positions and borrow during transform mode.
    ///      Only add audited contracts as transformers - they have significant privileges.
    /// @param transformer Address of the transformer contract
    /// @param active Whether the transformer should be active (true) or disabled (false)
    /// @custom:security Critical: Transformers can borrow and modify positions - ensure proper auditing
    function setTransformer(address transformer, bool active) external onlyOwner {
        // protects protocol from owner trying to set dangerous transformer
        if (
            transformer == address(0) || transformer == address(this) || transformer == asset
                || transformer == address(positionManager)
        ) {
            revert InvalidConfig();
        }

        transformerAllowList[transformer] = active;
        emit SetTransformer(transformer, active);
    }

    /// @notice set limits (this doesnt affect existing loans) - this method can be called by owner OR emergencyAdmin
    /// @param _minLoanSize min size of a loan - trying to create smaller loans will revert
    /// @param _globalLendLimit global limit of lent amount
    /// @param _globalDebtLimit global limit of debt amount
    /// @param _dailyLendIncreaseLimitMin min daily increasable amount of lent amount
    /// @param _dailyDebtIncreaseLimitMin min daily increasable amount of debt amount
    function setLimits(
        uint256 _minLoanSize,
        uint256 _globalLendLimit,
        uint256 _globalDebtLimit,
        uint256 _dailyLendIncreaseLimitMin,
        uint256 _dailyDebtIncreaseLimitMin
    ) external {
        if (msg.sender != emergencyAdmin && msg.sender != owner()) {
            revert Unauthorized();
        }

        minLoanSize = _minLoanSize;
        globalLendLimit = _globalLendLimit;
        globalDebtLimit = _globalDebtLimit;
        dailyLendIncreaseLimitMin = _dailyLendIncreaseLimitMin;
        dailyDebtIncreaseLimitMin = _dailyDebtIncreaseLimitMin;

        (, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        // force reset daily limits with new values
        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, true);
        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, true);

        emit SetLimits(
            _minLoanSize, _globalLendLimit, _globalDebtLimit, _dailyLendIncreaseLimitMin, _dailyDebtIncreaseLimitMin
        );
    }

    /// @notice sets reserve factor - percentage difference between debt and lend interest (onlyOwner)
    /// @param _reserveFactorX32 reserve factor multiplied by Q32
    function setReserveFactor(uint32 _reserveFactorX32) external onlyOwner {
        // update interest to be sure that reservefactor change is applied from now on
        _updateGlobalInterest();
        reserveFactorX32 = _reserveFactorX32;
        emit SetReserveFactor(_reserveFactorX32);
    }

    /// @notice sets reserve protection factor - percentage of globalLendAmount which can't be withdrawn by owner (onlyOwner)
    /// @param _reserveProtectionFactorX32 reserve protection factor multiplied by Q32
    function setReserveProtectionFactor(uint32 _reserveProtectionFactorX32) external onlyOwner {
        if (_reserveProtectionFactorX32 < MIN_RESERVE_PROTECTION_FACTOR_X32) {
            revert InvalidConfig();
        }
        reserveProtectionFactorX32 = _reserveProtectionFactorX32;
        emit SetReserveProtectionFactor(_reserveProtectionFactorX32);
    }

    /// @notice Sets or updates the collateral configuration for a token (onlyOwner)
    /// @dev Collateral factor determines how much of a token's value counts toward borrowing capacity.
    ///      Value limit prevents over-concentration of risk in a single collateral type.
    ///      Tokens not configured here are effectively non-borrowable collateral (factor defaults to 0 and value limit checks fail on debt increase).
    /// @param token Token address to configure (use address(0) for native ETH)
    /// @param collateralFactorX32 Collateral factor multiplied by Q32 (max 90%, e.g., 0.85 * Q32 for 85%)
    /// @param collateralValueLimitFactorX32 Max debt backed by this token as % of total lent, multiplied by Q32
    /// @custom:security Lower collateral factors for volatile tokens reduce liquidation risk
    function setTokenConfig(address token, uint32 collateralFactorX32, uint32 collateralValueLimitFactorX32)
        external
        onlyOwner
    {
        if (collateralFactorX32 > MAX_COLLATERAL_FACTOR_X32) {
            revert CollateralFactorExceedsMax();
        }
        TokenConfig storage config = tokenConfigs[token];
        config.collateralFactorX32 = collateralFactorX32; 
        config.collateralValueLimitFactorX32 = collateralValueLimitFactorX32;
        emit SetTokenConfig(token, collateralFactorX32, collateralValueLimitFactorX32);
    }

    /// @notice Sets or updates the allow list for a hook (onlyOwner)
    /// @param hook Hook to configure (address(0) for positions without hooks)
    /// @param isAllowed Whether the hook is allowed
    function setHookAllowList(address hook, bool isAllowed) external onlyOwner {
        hookAllowList[hook] = isAllowed;
        emit SetHookAllowList(hook, isAllowed);
    }

    /// @notice Updates emergency admin address (onlyOwner)
    /// @param admin Emergency admin address
    function setEmergencyAdmin(address admin) external onlyOwner {
        emergencyAdmin = admin;
        emit SetEmergencyAdmin(admin);
    }

    ////////////////// INTERNAL FUNCTIONS

    function _deposit(address receiver, uint256 amount, bool isShare)
        internal
        returns (uint256 assets, uint256 shares)
    {
        (, uint256 newLendExchangeRateX96) = _updateGlobalInterest();

        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, false);

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(shares, newLendExchangeRateX96, Math.Rounding.Ceil);
        } else {
            assets = amount;
            shares = _convertToShares(assets, newLendExchangeRateX96, Math.Rounding.Floor);
        }

        uint256 newTotalAssets = _convertToAssets(totalSupply() + shares, newLendExchangeRateX96, Math.Rounding.Ceil);
        if (newTotalAssets > globalLendLimit) {
            revert GlobalLendLimit();
        }
        if (assets > dailyLendIncreaseLimitLeft) {
            revert DailyLendIncreaseLimit();
        }

        dailyLendIncreaseLimitLeft = dailyLendIncreaseLimitLeft - assets;

        SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // withdraws lent tokens. can be denominated in token or share amount
    function _withdraw(address receiver, address owner, uint256 amount, bool isShare)
        internal
        returns (uint256 assets, uint256 shares)
    {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();
        _resetDailyLendIncreaseLimit(newLendExchangeRateX96, false);

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(amount, newLendExchangeRateX96, Math.Rounding.Floor);
        } else {
            assets = amount;
            shares = _convertToShares(amount, newLendExchangeRateX96, Math.Rounding.Ceil);
        }

        // if caller has allowance for owners shares - may call withdraw
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        (uint256 balance,) = _getBalanceAndReserves(newDebtExchangeRateX96, newLendExchangeRateX96);
        if (balance < assets) {
            revert InsufficientLiquidity();
        }

        // fails if not enough shares
        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset), receiver, assets);

        // when amounts are withdrawn - they may be deposited again
        dailyLendIncreaseLimitLeft = dailyLendIncreaseLimitLeft + assets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _repay(uint256 tokenId, uint256 amount, bool isShare)
        internal
        returns (uint256 assets, uint256 shares)
    {
        (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96) = _updateGlobalInterest();
        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, false);

        Loan storage loan = loans[tokenId];

        uint256 currentShares = loan.debtShares;

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(amount, newDebtExchangeRateX96, Math.Rounding.Ceil);
        } else {
            assets = amount;
            shares = _convertToShares(amount, newDebtExchangeRateX96, Math.Rounding.Floor);
        }

        if (shares == 0) {
            revert NoSharesRepayed();
        }

        // if too much repayed - just set to max
        if (shares > currentShares) {
            shares = currentShares;
            assets = _convertToAssets(shares, newDebtExchangeRateX96, Math.Rounding.Ceil);
        }

        if (assets > 0) {
            // fails if not enough token approved
            SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), assets);
        }

        uint256 loanDebtShares = currentShares - shares;
        loan.debtShares = loanDebtShares;
        debtSharesTotal = debtSharesTotal - shares;

        // when amounts are repayed - they maybe borrowed again
        dailyDebtIncreaseLimitLeft = dailyDebtIncreaseLimitLeft + assets;

        _updateAndCheckCollateral(
            tokenId, newDebtExchangeRateX96, newLendExchangeRateX96, loanDebtShares + shares, loanDebtShares
        );

        // if not fully repayed - check for loan size
        if (currentShares != shares) {
            // if resulting loan is too small - revert
            if (_convertToAssets(loanDebtShares, newDebtExchangeRateX96, Math.Rounding.Ceil) < minLoanSize) {
                revert MinLoanSize();
            }
        }

        emit Repay(tokenId, msg.sender, tokenOwner[tokenId], assets, shares);
    }

    function _getPositionTokens(uint256 tokenId) internal view returns (Currency token0, Currency token1) {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        token0 = poolKey.currency0;
        token1 = poolKey.currency1;
    }

    // checks how much balance is available
    function _getBalanceAndReserves(uint256 debtExchangeRateX96, uint256 lendExchangeRateX96)
        internal
        view
        returns (uint256 balance, uint256 reserves)
    {
        balance = Currency.wrap(asset).balanceOfSelf();
        uint256 debt = _convertToAssets(debtSharesTotal, debtExchangeRateX96, Math.Rounding.Ceil);
        uint256 lent = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Ceil);
        reserves = balance + debt > lent ? balance + debt - lent : 0;
    }

    // removes correct amount from position to send to liquidator
    function _sendPositionValue(
        LiquidateParams calldata params,
        uint256 liquidationValue,
        uint256 fullValue,
        uint256 feeValue
    ) internal returns (uint256 amount0, uint256 amount1) {
        uint128 liquidity;
        uint128 fees0;
        uint128 fees1;

        // if full position is liquidated - no analysis needed
        if (liquidationValue == fullValue) {
            liquidity = positionManager.getPositionLiquidity(params.tokenId);
        } else {
            (liquidity, fees0, fees1) = oracle.getLiquidityAndFees(params.tokenId);
            // calculate needed fees
            if (liquidationValue <= feeValue) {
                liquidity = 0;
                fees0 = SafeCast.toUint128(liquidationValue * fees0 / feeValue);
                fees1 = SafeCast.toUint128(liquidationValue * fees1 / feeValue);
            } else {
                liquidity = SafeCast.toUint128((liquidationValue - feeValue) * liquidity / (fullValue - feeValue));
            }
        }

        // decrease liquidity and collect fees/tokens
        (amount0, amount1) = _decreaseLiquidity(
            params.tokenId,
            liquidity,
            0,
            0,
            params.deadline,
            params.decreaseLiquidityHookData,
            (liquidationValue <= feeValue) ? address(this) : params.recipient // if all fees are taken - send directly to recipient
        );

        // if only part of the fees are taken - special handling needed
        if (liquidationValue <= feeValue) {
            _transferPartialFees(params.tokenId, params.recipient, amount0, amount1, fees0, fees1);
        }
    }

    // transfers partial fees to recipient and remaining tokens to position owner
    function _transferPartialFees(
        uint256 tokenId,
        address recipient,
        uint256 amount0,
        uint256 amount1,
        uint128 fees0,
        uint128 fees1
    ) internal {
        (Currency currency0, Currency currency1) = _getPositionTokens(tokenId);
        currency0.transfer(recipient, fees0);
        currency1.transfer(recipient, fees1);
        address owner = tokenOwner[tokenId];

        // wrap native ETH to WETH to prevent revert attacks from owner
        _transferTokenOrWeth(currency0, amount0 - fees0, owner);
        _transferTokenOrWeth(currency1, amount1 - fees1, owner);
    }

    // transfers token to recipient, wrapping native ETH to WETH to prevent revert attacks
    function _transferTokenOrWeth(Currency currency, uint256 amount, address recipient) internal {
        if (amount > 0) {
            if (currency.isAddressZero()) {
                weth.deposit{value: amount}();
                require(weth.transfer(recipient, amount), "WETH_TRANSFER_FAILED");
            } else {
                currency.transfer(recipient, amount);
            }
        }
    }

    // decreases liquidity from uniswap v4 position
    function _decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidityRemove, 
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        bytes memory decreaseLiquidityHookData,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {
        // Get position info to determine currencies for TAKE_PAIR
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        
        // Cache currencies to save gas
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;
        
        // check balance before decreasing liquidity
        amount0 = currency0.balanceOf(recipient);
        amount1 = currency1.balanceOf(recipient);

        // V4 uses different approach - need to use modifyLiquidities with encoded actions
        // Include both DECREASE_LIQUIDITY and TAKE_PAIR actions
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            tokenId,
            liquidityRemove,
            amount0Min,
            amount1Min,
            decreaseLiquidityHookData
        );
        paramsArray[1] = abi.encode(currency0, currency1, recipient);

        positionManager.modifyLiquidities(abi.encode(actions, paramsArray), deadline);

        // calculate delta
        amount0 = currency0.balanceOf(recipient) - amount0;
        amount1 = currency1.balanceOf(recipient) - amount1;
    }

    // cleans up loan when it is closed because of replacement, repayment or liquidation
    // the position is kept in the contract, but can be removed with remove() method
    // because loanShares are 0
    function _cleanupLoan(uint256 tokenId, uint256 debtExchangeRateX96, uint256 lendExchangeRateX96) internal {
        _updateAndCheckCollateral(tokenId, debtExchangeRateX96, lendExchangeRateX96, loans[tokenId].debtShares, 0);
        delete loans[tokenId];
    }

    // calculates amount which needs to be payed to liquidate position
    //  if position is too valuable - not all of the position is liquididated - only needed amount
    //  if position is not valuable enough - missing part is covered by reserves - if not enough reserves - collectively by other borrowers
    function _calculateLiquidation(uint256 debt, uint256 fullValue, uint256 collateralValue)
        internal
        pure
        returns (uint256 liquidationValue, uint256 liquidatorCost, uint256 reserveCost)
    {
        // in a standard liquidation - liquidator pays complete debt (and get part or all of position)
        // if position has less than enough value - liquidation cost maybe less - rest is payed by protocol or lenders collectively
        liquidatorCost = debt;

        // position value needed to pay debt at max penalty
        uint256 maxPenaltyValue = debt * (Q32 + MAX_LIQUIDATION_PENALTY_X32) / Q32;

        // if position is more valuable than debt with max penalty
        if (fullValue >= maxPenaltyValue) {
            if (collateralValue > 0) {
                // position value when position started to be liquidatable
                uint256 startLiquidationValue = debt * fullValue / collateralValue;
                uint256 penaltyFractionX96 =
                    (Q96 - ((fullValue - maxPenaltyValue) * Q96 / (startLiquidationValue - maxPenaltyValue)));
                uint256 penaltyX32 = MIN_LIQUIDATION_PENALTY_X32
                    + (MAX_LIQUIDATION_PENALTY_X32 - MIN_LIQUIDATION_PENALTY_X32) * penaltyFractionX96 / Q96;

                liquidationValue = debt * (Q32 + penaltyX32) / Q32;
            } else {
                liquidationValue = maxPenaltyValue;
            }
        } else {
            uint256 penalty = debt * MAX_LIQUIDATION_PENALTY_X32 / Q32;

            // if value is enough to pay penalty
            if (fullValue > penalty) {
                liquidatorCost = fullValue - penalty;
            } else {
                // this extreme case leads to free liquidation
                liquidatorCost = 0;
            }

            liquidationValue = fullValue;
            reserveCost = debt - liquidatorCost; // Remaining to pay is taken from reserves
        }
    }

    // calculates if there are enough reserves to cover liquidaton - if not its shared between lenders
    function _handleReserveLiquidation(
        uint256 reserveCost,
        uint256 newDebtExchangeRateX96,
        uint256 newLendExchangeRateX96
    ) internal returns (uint256 missing) {
        (, uint256 reserves) = _getBalanceAndReserves(newDebtExchangeRateX96, newLendExchangeRateX96);

        // if not enough - democratize debt
        if (reserveCost > reserves) {
            missing = reserveCost - reserves;

            uint256 totalLent = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Ceil);

            // If liquidation losses wipe all lender principal, the lender exchange rate collapses to zero.
            if (totalLent == 0 || missing >= totalLent) {
                newLendExchangeRateX96 = 0;
            } else {
                // Distribute the missing amount proportionally across all lent assets.
                newLendExchangeRateX96 = (totalLent - missing) * newLendExchangeRateX96 / totalLent;
            }
            lastLendExchangeRateX96 = newLendExchangeRateX96;
            emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
        }
    }

    function _calculateTokenCollateralFactorX32(uint256 tokenId) internal view returns (uint32) {
        // Get position info to determine currencies
        (Currency currency0, Currency currency1) = _getPositionTokens(tokenId);
        uint32 factor0X32 = tokenConfigs[Currency.unwrap(currency0)].collateralFactorX32;
        uint32 factor1X32 = tokenConfigs[Currency.unwrap(currency1)].collateralFactorX32;
        return factor0X32 > factor1X32 ? factor1X32 : factor0X32;
    }

    function _updateGlobalInterest()
        internal
        returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96)
    {
        // only needs to be updated once per block (when needed)
        if (block.timestamp > lastExchangeRateUpdate) {
            (newDebtExchangeRateX96, newLendExchangeRateX96) = _calculateGlobalInterest();
            lastDebtExchangeRateX96 = newDebtExchangeRateX96;
            lastLendExchangeRateX96 = newLendExchangeRateX96;
            lastExchangeRateUpdate = uint64(block.timestamp); // never overflows in a loooooong time
            emit ExchangeRateUpdate(newDebtExchangeRateX96, newLendExchangeRateX96);
        } else {
            newDebtExchangeRateX96 = lastDebtExchangeRateX96;
            newLendExchangeRateX96 = lastLendExchangeRateX96;
        }
    }

    function _calculateGlobalInterest()
        internal
        view
        returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96)
    {
        uint256 oldDebtExchangeRateX96 = lastDebtExchangeRateX96;
        uint256 oldLendExchangeRateX96 = lastLendExchangeRateX96;

        // always growing or equal
        uint256 lastRateUpdate = lastExchangeRateUpdate;
        uint256 timeElapsed = (block.timestamp - lastRateUpdate);

        if (timeElapsed > 0 && lastRateUpdate != 0) {

            (uint256 balance,) = _getBalanceAndReserves(oldDebtExchangeRateX96, oldLendExchangeRateX96);
            uint256 debt = _convertToAssets(debtSharesTotal, oldDebtExchangeRateX96, Math.Rounding.Ceil);
            (uint256 borrowRateX64, uint256 supplyRateX64) = interestRateModel.getRatesPerSecondX64(balance, debt);
            supplyRateX64 = supplyRateX64.mulDiv(Q32 - reserveFactorX32, Q32);

            newDebtExchangeRateX96 = oldDebtExchangeRateX96 + oldDebtExchangeRateX96 * timeElapsed * borrowRateX64 / Q64;
            newLendExchangeRateX96 = oldLendExchangeRateX96 + oldLendExchangeRateX96 * timeElapsed * supplyRateX64 / Q64;
        } else {
            newDebtExchangeRateX96 = oldDebtExchangeRateX96;
            newLendExchangeRateX96 = oldLendExchangeRateX96;
        }
    }

    function _requireLoanIsHealthy(uint256 tokenId, uint256 debt) internal view {
        (bool isHealthy,,,) = _checkLoanIsHealthy(tokenId, debt);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    // updates collateral token configs - and check if limit is not surpassed (check is only done on increasing debt shares)
    function _updateAndCheckCollateral(
        uint256 tokenId,
        uint256 debtExchangeRateX96,
        uint256 lendExchangeRateX96,
        uint256 oldShares,
        uint256 newShares
    ) internal {
        if (oldShares != newShares) {
            (Currency currency0, Currency currency1) = _getPositionTokens(tokenId);
            address token0 = Currency.unwrap(currency0);
            address token1 = Currency.unwrap(currency1);

            // remove previous collateral - add new collateral
            if (oldShares > newShares) {
                uint192 difference = _toUint192(oldShares - newShares);
                tokenConfigs[token0].totalDebtShares -= difference;
                tokenConfigs[token1].totalDebtShares -= difference;
            } else {
                uint192 difference = _toUint192(newShares - oldShares);
                tokenConfigs[token0].totalDebtShares += difference;
                tokenConfigs[token1].totalDebtShares += difference;

                // check if current value of used collateral is more than allowed limit
                // if collateral is decreased - never revert
                uint256 lentAssets = _convertToAssets(totalSupply(), lendExchangeRateX96, Math.Rounding.Ceil);
                uint256 collateralValueLimitFactorX32 = tokenConfigs[token0].collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max
                        && _convertToAssets(tokenConfigs[token0].totalDebtShares, debtExchangeRateX96, Math.Rounding.Ceil)
                            > lentAssets * collateralValueLimitFactorX32 / Q32
                ) {
                    revert CollateralValueLimit();
                }
                collateralValueLimitFactorX32 = tokenConfigs[token1].collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max
                        && _convertToAssets(tokenConfigs[token1].totalDebtShares, debtExchangeRateX96, Math.Rounding.Ceil)
                            > lentAssets * collateralValueLimitFactorX32 / Q32
                ) {
                    revert CollateralValueLimit();
                }
            }
        }
    }

    function _resetDailyLendIncreaseLimit(uint256 newLendExchangeRateX96, bool force) internal {
        uint32 time = uint32(block.timestamp / 1 days);
        if (force || time > dailyLendIncreaseLimitLastReset) {
            dailyLendIncreaseLimitLeft = _calculateDailyLimit(newLendExchangeRateX96, dailyLendIncreaseLimitMin, MAX_DAILY_LEND_INCREASE_X32);
            dailyLendIncreaseLimitLastReset = time;
        }
    }

    function _resetDailyDebtIncreaseLimit(uint256 newLendExchangeRateX96, bool force) internal {
        uint32 time = uint32(block.timestamp / 1 days);
        if (force || time > dailyDebtIncreaseLimitLastReset) {
            dailyDebtIncreaseLimitLeft = _calculateDailyLimit(newLendExchangeRateX96, dailyDebtIncreaseLimitMin, MAX_DAILY_DEBT_INCREASE_X32);
            dailyDebtIncreaseLimitLastReset = time;
        }
    }

    function _calculateDailyLimit(
        uint256 newLendExchangeRateX96,
        uint256 limitMin,
        uint32 maxFactorX32
    ) internal view returns (uint256) {
        uint256 increaseLimit = _convertToAssets(totalSupply(), newLendExchangeRateX96, Math.Rounding.Ceil) * maxFactorX32 / Q32;
        return limitMin > increaseLimit ? limitMin : increaseLimit;
    }

    function _checkLoanIsHealthy(uint256 tokenId, uint256 debt)
        internal
        view
        returns (bool isHealthy, uint256 fullValue, uint256 collateralValue, uint256 feeValue)
    {
        (fullValue, feeValue,,) = oracle.getValue(tokenId, address(asset));
        uint256 collateralFactorX32 = _calculateTokenCollateralFactorX32(tokenId);
        collateralValue = fullValue.mulDiv(collateralFactorX32, Q32);
        isHealthy = collateralValue >= debt;
    }

    function _convertToShares(uint256 amount, uint256 exchangeRateX96, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return amount.mulDiv(Q96, exchangeRateX96, rounding);
    }

    function _convertToAssets(uint256 shares, uint256 exchangeRateX96, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return shares.mulDiv(exchangeRateX96, Q96, rounding);
    }

    function _addTokenToOwner(address to, uint256 tokenId) internal {
        ownedTokensIndex[tokenId] = ownedTokens[to].length;
        ownedTokens[to].push(tokenId);
        tokenOwner[tokenId] = to;
    }

    function _checkHookAllowed(uint256 tokenId) internal view {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        if (!hookAllowList[address(poolKey.hooks)]) {
            revert HookNotAllowed();
        }
    }

    function _removeTokenFromOwner(address from, uint256 tokenId) internal {
        uint256 lastTokenIndex = ownedTokens[from].length - 1;
        uint256 tokenIndex = ownedTokensIndex[tokenId];
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedTokens[from][lastTokenIndex];
            ownedTokens[from][tokenIndex] = lastTokenId;
            ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        ownedTokens[from].pop();
        // Note that ownedTokensIndex[tokenId] is not deleted. There is no need to delete it - gas optimization
        delete tokenOwner[tokenId]; // Remove the token from the token owner mapping
    }

    function _toUint192(uint256 value) internal pure returns (uint192) {
        if (value > type(uint192).max) {
            revert();
        }
        return SafeCast.toUint192(value);
    }

    // recieves ETH from fees or when decreasing liquidity
    receive() external payable {
    }
}
