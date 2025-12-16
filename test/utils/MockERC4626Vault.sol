// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MockERC4626Vault
/// @notice A simple ERC4626 vault implementation for testing autolend functionality
/// @dev Uses 1:1 asset to share ratio for simplicity (can be extended with yield if needed)
contract MockERC4626Vault is ERC20, IERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 private immutable _asset;
    uint8 private immutable _decimals;

    /// @notice Exchange rate between assets and shares (1e18 = 1:1 ratio)
    /// @dev Can be modified to simulate yield
    uint256 public exchangeRate = 1e18;

    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);

    /// @param asset_ The underlying asset token
    /// @param name_ Name of the vault share token
    /// @param symbol_ Symbol of the vault share token
    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
    {
        _asset = asset_;
        _decimals = ERC20(address(asset_)).decimals();
    }

    /// @notice Returns the underlying asset token
    function asset() public view virtual override returns (address) {
        return address(_asset);
    }

    /// @notice Returns the total amount of assets managed by the vault
    function totalAssets() public view virtual override returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    /// @notice Converts assets to shares using the exchange rate
    function convertToShares(uint256 assets) public view virtual override returns (uint256) {
        return assets.mulDiv(exchangeRate, 1e18, Math.Rounding.Floor);
    }

    /// @notice Converts shares to assets using the exchange rate
    function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
        return shares.mulDiv(1e18, exchangeRate, Math.Rounding.Floor);
    }

    /// @notice Returns the maximum amount of assets that can be deposited
    function maxDeposit(address) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns the maximum amount of shares that can be minted
    function maxMint(address) public view virtual override returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Returns the maximum amount of assets that can be withdrawn by the owner
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /// @notice Returns the maximum amount of shares that can be redeemed by the owner
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        return balanceOf(owner);
    }

    /// @notice Preview the amount of shares that would be received for depositing assets
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Preview the amount of assets that would be required to mint shares
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        return shares.mulDiv(1e18, exchangeRate, Math.Rounding.Ceil);
    }

    /// @notice Preview the amount of assets that would be received for redeeming shares
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return convertToAssets(shares);
    }

    /// @notice Preview the amount of shares that would be required to withdraw assets
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        return assets.mulDiv(exchangeRate, 1e18, Math.Rounding.Ceil);
    }

    /// @notice Deposit assets and receive shares
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive the shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override
        returns (uint256 shares)
    {
        require(assets <= maxDeposit(receiver), "ERC4626: deposit more than max");

        shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        return shares;
    }

    /// @notice Mint shares by depositing assets
    /// @param shares Amount of shares to mint
    /// @param receiver Address to receive the shares
    /// @return assets Amount of assets deposited
    function mint(uint256 shares, address receiver)
        public
        virtual
        override
        returns (uint256 assets)
    {
        require(shares <= maxMint(receiver), "ERC4626: mint more than max");

        assets = previewMint(shares);
        _deposit(_msgSender(), receiver, assets, shares);

        return assets;
    }

    /// @notice Withdraw assets by burning shares
    /// @param assets Amount of assets to withdraw
    /// @param receiver Address to receive the assets
    /// @param owner Address that owns the shares
    /// @return shares Amount of shares burned
    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        returns (uint256 shares)
    {
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");

        shares = previewWithdraw(assets);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return shares;
    }

    /// @notice Redeem shares for assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the assets
    /// @param owner Address that owns the shares
    /// @return assets Amount of assets received
    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override
        returns (uint256 assets)
    {
        require(shares <= maxRedeem(owner), "ERC4626: redeem more than max");

        assets = previewRedeem(shares);
        _withdraw(_msgSender(), receiver, owner, assets, shares);

        return assets;
    }

    /// @notice Internal function to handle deposit
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        virtual
    {
        // If caller is the contract itself, skip transfer (for testing)
        if (caller != address(this)) {
            _asset.safeTransferFrom(caller, address(this), assets);
        }

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /// @notice Internal function to handle withdrawal
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);
        _asset.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Returns the decimals of the vault token (same as underlying asset)
    function decimals() public view virtual override(ERC20, IERC20Metadata) returns (uint8) {
        return _decimals;
    }

    /// @notice Simulate yield by increasing exchange rate
    /// @param yieldBps Yield in basis points (e.g., 100 = 1%)
    function simulateYield(uint256 yieldBps) external {
        uint256 oldRate = exchangeRate;
        exchangeRate = oldRate + (oldRate * yieldBps / 10000);
        emit ExchangeRateUpdated(oldRate, exchangeRate);
    }
}

