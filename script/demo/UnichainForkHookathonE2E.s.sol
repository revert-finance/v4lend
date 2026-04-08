// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "@uniswap/v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IUniversalRouter} from "src/shared/swap/IUniversalRouter.sol";
import {LiquidityCalculator, ILiquidityCalculator} from "src/shared/math/LiquidityCalculator.sol";
import {V4Oracle} from "src/oracle/V4Oracle.sol";
import {InterestRateModel} from "src/vault/InterestRateModel.sol";
import {V4Vault} from "src/vault/V4Vault.sol";
import {FlashloanLiquidator} from "src/vault/liquidation/FlashloanLiquidator.sol";
import {V4Utils} from "src/vault/transformers/V4Utils.sol";
import {LeverageTransformer} from "src/vault/transformers/LeverageTransformer.sol";
import {RevertHook} from "src/RevertHook.sol";
import {RevertHookState} from "src/hook/RevertHookState.sol";
import {HookFeeController} from "src/hook/HookFeeController.sol";
import {RevertHookSwapActions} from "src/hook/RevertHookSwapActions.sol";
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";

import {DemoERC20} from "./support/DemoERC20.sol";
import {MockAggregatorV3} from "./support/MockAggregatorV3.sol";

contract UnichainForkHookathonE2E is Script {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;

    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0x4529A01c7A0410167c5740C487A8DE60232617bf);
    IUniversalRouter internal constant UNIVERSAL_ROUTER = IUniversalRouter(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IWETH9 internal constant WETH = IWETH9(0x4200000000000000000000000000000000000006);
    uint16 internal constant PROTOCOL_FEE_BPS = 100;
    int24 internal constant MAX_TICKS_FROM_ORACLE = 100;
    uint256 internal constant MIN_POSITION_VALUE_NATIVE = 0.01 ether;

    uint256 internal constant BASE_RATE_PER_YEAR = 0;
    uint256 internal constant MULTIPLIER_PER_YEAR = Q64 * 5 / 100;
    uint256 internal constant JUMP_MULTIPLIER_PER_YEAR = Q64 * 109 / 100;
    uint256 internal constant KINK = Q64 * 80 / 100;

    uint32 internal constant MAX_FEED_AGE = 7 days;
    uint16 internal constant MAX_POOL_PRICE_DIFFERENCE = 200;

    uint32 internal constant CF_DEMO = uint32(Q32 * 850 / 1000);

    uint256 internal constant MIN_LOAN_SIZE = 0.1 ether;
    uint256 internal constant GLOBAL_LEND_LIMIT = 1_000_000 ether;
    uint256 internal constant GLOBAL_DEBT_LIMIT = 1_000_000 ether;
    uint256 internal constant DAILY_LEND_INCREASE_LIMIT_MIN = 100_000 ether;
    uint256 internal constant DAILY_DEBT_INCREASE_LIMIT_MIN = 100_000 ether;
    uint256 internal constant MAX_LOOP = 500_000;

    bytes32 internal constant AUTO_RANGE_TOPIC =
        keccak256("AutoRange(uint256,uint256,address,address,uint256,uint256)");
    bytes32 internal constant AUTO_EXIT_TOPIC = keccak256("AutoExit(uint256,address,address,uint256,uint256)");
    bytes32 internal constant AUTO_LEVERAGE_TOPIC = keccak256("AutoLeverage(uint256,bool,uint256,uint256)");
    uint256 internal constant DEFAULT_DEMO_PRIVATE_KEY =
        0xA11CE00000000000000000000000000000000000000000000000000000001234;

    struct DeploymentResult {
        DemoERC20 demoUsd;
        DemoERC20 demoEth;
        MockAggregatorV3 usdFeed;
        MockAggregatorV3 ethFeed;
        InterestRateModel interestRateModel;
        LiquidityCalculator liquidityCalculator;
        V4Oracle oracle;
        RevertHookPositionActions positionActions;
        RevertHookAutoLeverageActions autoLeverageActions;
        RevertHookAutoLendActions autoLendActions;
        RevertHook revertHook;
        V4Vault vault;
        FlashloanLiquidator flashloanLiquidator;
        V4Utils v4Utils;
        LeverageTransformer leverageTransformer;
        PoolKey poolKey;
    }

    struct LoanSnapshot {
        uint256 debt;
        uint256 fullValue;
        uint256 collateralValue;
    }

    function run() external {
        string memory rpcUrl = vm.envOr("UNICHAIN_RPC_URL", string("https://mainnet.unichain.org"));
        vm.createSelectFork(rpcUrl);

        uint256 deployerPrivateKey = vm.envOr("DEMO_PRIVATE_KEY", DEFAULT_DEMO_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);
        vm.deal(deployer, 100 ether);

        _logBanner("Unichain Fork Hookathon Demo");
        console.log("Fork RPC:", rpcUrl);
        console.log("Demo operator:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        DeploymentResult memory deployment = _deployAll(deployer);
        uint256 ambientTokenId = _mintAmbientPosition(deployment, deployer);
        uint256 tokenId = _mintHookedPosition(deployment, deployer);
        _setupVaultPosition(deployment, tokenId, deployer);

        RevertHookState.PositionConfig memory config = _configureAutoRangeAutoExitAndAutoLeverage(deployment, tokenId);
        uint256 rangedTokenId = _runAutoRangePhase(deployment, tokenId, deployer, config);
        uint256 exitedTokenId = _runAutoExitPhase(deployment, rangedTokenId, config);

        vm.stopBroadcast();

        _logBanner("Demo Completed Successfully");
        console.log("Hook:", address(deployment.revertHook));
        console.log("Vault:", address(deployment.vault));
        console.log("Ambient tokenId:", ambientTokenId);
        console.log("Initial tokenId:", tokenId);
        console.log("Ranged tokenId:", rangedTokenId);
        console.log("Exited tokenId:", exitedTokenId);
    }

    function _deployAll(address deployer) internal returns (DeploymentResult memory deployment) {
        deployment.demoUsd = new DemoERC20("Hookathon Demo USD", "hUSD", 18);
        deployment.demoEth = new DemoERC20("Hookathon Demo ETH", "hETH", 18);
        deployment.demoUsd.mint(deployer, 1_000_000 ether);
        deployment.demoEth.mint(deployer, 1_000_000 ether);

        deployment.usdFeed = new MockAggregatorV3(8, 1e8);
        deployment.ethFeed = new MockAggregatorV3(8, 1e8);

        deployment.interestRateModel =
            new InterestRateModel(BASE_RATE_PER_YEAR, MULTIPLIER_PER_YEAR, JUMP_MULTIPLIER_PER_YEAR, KINK);
        deployment.liquidityCalculator = new LiquidityCalculator();

        deployment.oracle = new V4Oracle(POSITION_MANAGER, address(deployment.demoEth), address(0));
        deployment.oracle.setMaxPoolPriceDifference(MAX_POOL_PRICE_DIFFERENCE);
        deployment.oracle.setTokenConfig(address(deployment.demoUsd), deployment.usdFeed, MAX_FEED_AGE);
        deployment.oracle.setTokenConfig(address(deployment.demoEth), deployment.ethFeed, MAX_FEED_AGE);
        deployment.oracle.setTokenConfig(address(0), deployment.ethFeed, MAX_FEED_AGE);

        uint64 hookSidecarNonce = vm.getNonce(deployer);
        address predictedFeeController = vm.computeCreateAddress(deployer, hookSidecarNonce);
        address predictedSwapActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 1);
        address predictedPositionActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 2);
        address predictedAutoLeverageActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 3);
        address predictedAutoLendActions = vm.computeCreateAddress(deployer, hookSidecarNonce + 4);

        bytes memory constructorArgs = abi.encode(
            deployer,
            PERMIT2,
            deployment.oracle,
            ILiquidityCalculator(deployment.liquidityCalculator),
            HookFeeController(predictedFeeController),
            RevertHookPositionActions(predictedPositionActions),
            RevertHookAutoLeverageActions(predictedAutoLeverageActions),
            RevertHookAutoLendActions(predictedAutoLendActions)
        );
        bytes memory creationCodeWithArgs = abi.encodePacked(type(RevertHook).creationCode, constructorArgs);
        (address expectedHookAddress, bytes32 salt) = findHookSalt(CREATE2_DEPLOYER, creationCodeWithArgs);

        HookFeeController feeController =
            new HookFeeController(expectedHookAddress, deployer, PROTOCOL_FEE_BPS, PROTOCOL_FEE_BPS);
        require(address(feeController) == predictedFeeController, "Demo: fee controller address mismatch");
        RevertHookSwapActions swapActions = new RevertHookSwapActions(deployment.oracle, feeController);
        require(address(swapActions) == predictedSwapActions, "Demo: swap actions address mismatch");

        deployment.positionActions = new RevertHookPositionActions(
            PERMIT2, deployment.oracle, ILiquidityCalculator(deployment.liquidityCalculator), swapActions
        );
        deployment.autoLeverageActions = new RevertHookAutoLeverageActions(
            PERMIT2, deployment.oracle, ILiquidityCalculator(deployment.liquidityCalculator), swapActions
        );
        deployment.autoLendActions = new RevertHookAutoLendActions(
            PERMIT2, deployment.oracle, ILiquidityCalculator(deployment.liquidityCalculator), feeController, swapActions
        );
        deployment.revertHook = new RevertHook{salt: salt}(
            deployer,
            PERMIT2,
            deployment.oracle,
            ILiquidityCalculator(deployment.liquidityCalculator),
            feeController,
            deployment.positionActions,
            deployment.autoLeverageActions,
            deployment.autoLendActions
        );
        require(address(deployment.revertHook) == expectedHookAddress, "Demo: hook address mismatch");
        deployment.revertHook.setMaxTicksFromOracle(MAX_TICKS_FROM_ORACLE);
        deployment.revertHook.setMinPositionValueNative(MIN_POSITION_VALUE_NATIVE);

        deployment.vault = new V4Vault(
            "Hookathon Demo Vault",
            "hdUSD",
            address(deployment.demoUsd),
            POSITION_MANAGER,
            deployment.interestRateModel,
            deployment.oracle,
            WETH
        );
        deployment.vault.setTokenConfig(address(deployment.demoUsd), CF_DEMO, type(uint32).max);
        deployment.vault.setTokenConfig(address(deployment.demoEth), CF_DEMO, type(uint32).max);
        deployment.vault
            .setLimits(
                MIN_LOAN_SIZE,
                GLOBAL_LEND_LIMIT,
                GLOBAL_DEBT_LIMIT,
                DAILY_LEND_INCREASE_LIMIT_MIN,
                DAILY_DEBT_INCREASE_LIMIT_MIN
            );
        deployment.vault.setReserveFactor(uint32(Q32 * 10 / 100));
        deployment.vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));

        deployment.flashloanLiquidator =
            new FlashloanLiquidator(POSITION_MANAGER, address(UNIVERSAL_ROUTER), address(0));
        deployment.v4Utils = new V4Utils(POSITION_MANAGER, address(UNIVERSAL_ROUTER), address(0), PERMIT2);
        deployment.leverageTransformer =
            new LeverageTransformer(POSITION_MANAGER, address(UNIVERSAL_ROUTER), address(0), PERMIT2);

        deployment.v4Utils.setVault(address(deployment.vault));
        deployment.vault.setTransformer(address(deployment.v4Utils), true);
        deployment.leverageTransformer.setVault(address(deployment.vault));
        deployment.vault.setTransformer(address(deployment.leverageTransformer), true);
        deployment.revertHook.setVault(address(deployment.vault));
        deployment.vault.setTransformer(address(deployment.revertHook), true);
        deployment.vault.setHookAllowList(address(deployment.revertHook), true);
        deployment.revertHook.setAutoLendVault(address(deployment.demoUsd), deployment.vault);

        deployment.poolKey = _buildHookedPoolKey(
            address(deployment.demoUsd), address(deployment.demoEth), address(deployment.revertHook)
        );
        _initializePool(deployment.poolKey);
        _approveAll(deployment, deployer);

        _logSection("1. Deploy demo stack and initialize the hooked pool");
        console.log("Hook:", address(deployment.revertHook));
        console.log("Vault:", address(deployment.vault));
        console.log("Pool token0:", Currency.unwrap(deployment.poolKey.currency0));
        console.log("Pool token1:", Currency.unwrap(deployment.poolKey.currency1));
        console.log("Starting tick:", int256(_currentTick(deployment.poolKey)));
    }

    function _mintHookedPosition(DeploymentResult memory deployment, address owner) internal returns (uint256 tokenId) {
        int24 tickLower = int24(vm.envOr("DEMO_TICK_LOWER", int256(-60)));
        int24 tickUpper = int24(vm.envOr("DEMO_TICK_UPPER", int256(60)));
        uint128 liquidity = uint128(vm.envOr("DEMO_POSITION_LIQUIDITY", uint256(5e18)));

        tokenId = _mintPosition(deployment, owner, tickLower, tickUpper, liquidity, "hooked");
    }

    function _mintAmbientPosition(DeploymentResult memory deployment, address owner)
        internal
        returns (uint256 tokenId)
    {
        int24 tickLower = int24(vm.envOr("AMBIENT_TICK_LOWER", int256(-6000)));
        int24 tickUpper = int24(vm.envOr("AMBIENT_TICK_UPPER", int256(6000)));
        uint128 liquidity = uint128(vm.envOr("AMBIENT_POSITION_LIQUIDITY", uint256(5e18)));

        tokenId = _mintPosition(deployment, owner, tickLower, tickUpper, liquidity, "ambient");
    }

    function _mintPosition(
        DeploymentResult memory deployment,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        string memory label
    ) internal returns (uint256 tokenId) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory paramsArray = new bytes[](2);
        paramsArray[0] = abi.encode(
            deployment.poolKey, tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max, owner, bytes("")
        );
        paramsArray[1] = abi.encode(deployment.poolKey.currency0, deployment.poolKey.currency1, owner);

        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, paramsArray), _deadline());
        tokenId = POSITION_MANAGER.nextTokenId() - 1;
        require(tokenId >= nextTokenIdBefore, "Demo: position mint failed");

        console.log("Minted position type:", label);
        console.log("  tokenId:", tokenId);
        console.log("  range lower:", int256(tickLower));
        console.log("  range upper:", int256(tickUpper));
    }

    function _setupVaultPosition(DeploymentResult memory deployment, uint256 tokenId, address owner) internal {
        _logSection("2. Move the position into the vault with zero debt");

        uint256 vaultDeposit = vm.envOr("DEMO_VAULT_DEPOSIT", uint256(100_000 ether));

        deployment.oracle.setMaxPoolPriceDifference(10_000);
        deployment.revertHook.setMaxTicksFromOracle(10_000);
        deployment.vault.setLimits(0, GLOBAL_LEND_LIMIT, GLOBAL_DEBT_LIMIT, GLOBAL_LEND_LIMIT, GLOBAL_DEBT_LIMIT);
        deployment.demoUsd.approve(address(deployment.vault), type(uint256).max);

        deployment.vault.deposit(vaultDeposit, owner);
        console.log("Vault funded with demo USD:", vaultDeposit);

        IERC721(address(POSITION_MANAGER)).approve(address(deployment.vault), tokenId);
        deployment.vault.create(tokenId, owner);
        deployment.vault.approveTransform(tokenId, address(deployment.revertHook), true);

        console.log("Position moved into vault custody.");
        console.log("  NFT owner:", IERC721(address(POSITION_MANAGER)).ownerOf(tokenId));
        console.log("  Loan owner:", deployment.vault.ownerOf(tokenId));
        _logLoanState("Loan state before automation", _loanSnapshot(deployment.vault, tokenId));
    }

    function _configureAutoRangeAutoExitAndAutoLeverage(DeploymentResult memory deployment, uint256 tokenId)
        internal
        returns (RevertHookState.PositionConfig memory config)
    {
        _logSection("3. Activate AUTO_LEVERAGE, AUTO_RANGE, and lower-side AUTO_EXIT together");

        RevertHook hook = deployment.revertHook;
        LoanSnapshot memory before = _loanSnapshot(deployment.vault, tokenId);
        uint32 maxPriceImpactBps = uint32(vm.envOr("DEMO_MAX_PRICE_IMPACT_BPS", uint256(10000)));

        hook.setGeneralConfig(tokenId, 0, 0, IHooks(address(0)), maxPriceImpactBps, maxPriceImpactBps);

        int24 spacing = _poolTickSpacing(tokenId);
        int24 upperLimitSpacings = int24(vm.envOr("DEMO_AUTO_RANGE_UPPER_LIMIT_SPACINGS", int256(4)));
        int24 lowerLimitSpacings = int24(vm.envOr("DEMO_AUTO_RANGE_LOWER_LIMIT_SPACINGS", int256(20)));
        int24 exitLowerDeltaSpacings = int24(vm.envOr("DEMO_AUTO_EXIT_LOWER_DELTA_SPACINGS", int256(1)));
        uint16 leverageTargetBps = uint16(vm.envOr("DEMO_AUTO_LEVERAGE_TARGET_BPS", uint256(5000)));
        require(exitLowerDeltaSpacings > 0, "Demo: exit lower delta must be positive");

        config = RevertHookState.PositionConfig({
            modeFlags: PositionModeFlags.MODE_AUTO_RANGE | PositionModeFlags.MODE_AUTO_EXIT
                | PositionModeFlags.MODE_AUTO_LEVERAGE,
            autoCollectMode: RevertHookState.AutoCollectMode.NONE,
            autoExitIsRelative: true,
            autoExitTickLower: exitLowerDeltaSpacings * spacing,
            autoExitTickUpper: type(int24).max,
            autoExitSwapOnLowerTrigger: true,
            autoExitSwapOnUpperTrigger: true,
            autoRangeLowerLimit: lowerLimitSpacings * spacing,
            autoRangeUpperLimit: upperLimitSpacings * spacing,
            autoRangeLowerDelta: -spacing,
            autoRangeUpperDelta: spacing,
            autoLendToleranceTick: 0,
            autoLeverageTargetBps: leverageTargetBps
        });

        vm.recordLogs();
        hook.setPositionConfig(tokenId, config);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (
            bool sawAutoLeverage,
            uint256 eventTokenId,
            bool isUpperTrigger,
            uint256 debtBeforeEvent,
            uint256 debtAfterEvent
        ) = _findAutoLeverage(entries, address(deployment.revertHook));
        (bool sawAutoRange,,) = _findAutoRange(entries, address(deployment.revertHook));

        require(sawAutoLeverage, "Demo: AutoLeverage event not found");
        require(!sawAutoRange, "Demo: AUTO_RANGE should not fire during config");
        require(eventTokenId == tokenId, "Demo: unexpected AutoLeverage tokenId");
        require(isUpperTrigger, "Demo: expected immediate leverage-up during config");

        LoanSnapshot memory afterLeverage = _loanSnapshot(deployment.vault, tokenId);
        int24 baseTickAfter = _autoLeverageBaseTick(deployment.revertHook, tokenId);
        require(afterLeverage.debt > before.debt, "Demo: immediate leverage should increase debt");

        console.log("Configuration immediately triggered AUTO_LEVERAGE.");
        console.log("  event debt before:", debtBeforeEvent);
        console.log("  event debt after:", debtAfterEvent);
        console.log("  refreshed base tick:", int256(baseTickAfter));
        _logLoanState("Loan after immediate leverage", afterLeverage);
        _logTriggerPlan(hook, tokenId, config);
    }

    function _runAutoRangePhase(
        DeploymentResult memory deployment,
        uint256 tokenId,
        address owner,
        RevertHookState.PositionConfig memory expectedConfig
    ) internal returns (uint256 newTokenId) {
        _logSection("4. Push price upward until AUTO_RANGE remints the position");

        (, PositionInfo oldPositionInfo) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        LoanSnapshot memory before = _loanSnapshot(deployment.vault, tokenId);
        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();
        uint256 maxSteps = vm.envOr("DEMO_MAX_RANGE_STEPS", uint256(16));
        uint128 amountInPerStep = uint128(vm.envOr("DEMO_RANGE_SWAP_STEP_AMOUNT", uint256(0.05 ether)));
        int24 spacing = deployment.poolKey.tickSpacing;
        int24 baseTick = _autoLeverageBaseTick(deployment.revertHook, tokenId);
        int24 nextLeverageUpperTrigger = baseTick + 10 * spacing;
        int24 rangeUpperTrigger = oldPositionInfo.tickUpper() + expectedConfig.autoRangeUpperLimit;

        console.log("Starting tokenId for range phase:", tokenId);
        console.log("Current tick:", int256(_currentTick(deployment.poolKey)));
        console.log("Current upper range edge:", int256(oldPositionInfo.tickUpper()));
        console.log("Next leverage upper trigger:", int256(nextLeverageUpperTrigger));
        console.log("Range upper trigger:", int256(rangeUpperTrigger));
        console.log("Range should fire before the next upper leverage trigger.");

        vm.recordLogs();

        bool triggered;
        for (uint256 step; step < maxSteps; ++step) {
            int24 tickBefore = _currentTick(deployment.poolKey);
            _logSwapStep("Range hunt", step + 1, tickBefore, amountInPerStep, false);
            _swapExactInputSingle(deployment.poolKey, false, amountInPerStep);

            int24 tickAfter = _currentTick(deployment.poolKey);
            console.log("  tick after:", int256(tickAfter));

            if (POSITION_MANAGER.nextTokenId() > nextTokenIdBefore) {
                triggered = true;
                break;
            }
        }

        require(triggered, "Demo: AUTO_RANGE did not remint the position");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (bool sawAutoRange, uint256 oldTokenIdFromEvent, uint256 newTokenIdFromEvent) =
            _findAutoRange(entries, address(deployment.revertHook));
        (bool sawAutoExit, uint256 exitTokenIdFromEvent) = _findAutoExit(entries, address(deployment.revertHook));
        (bool sawAutoLeverage,,,,) = _findAutoLeverage(entries, address(deployment.revertHook));

        require(sawAutoRange, "Demo: AutoRange event not found");
        require(!sawAutoExit, "Demo: AUTO_EXIT should not fire during range phase");
        require(!sawAutoLeverage, "Demo: unexpected second leverage execution during range phase");
        require(oldTokenIdFromEvent == tokenId, "Demo: unexpected AutoRange source token");
        require(exitTokenIdFromEvent == 0, "Demo: unexpected AutoExit token");

        newTokenId = POSITION_MANAGER.nextTokenId() - 1;
        require(newTokenId == newTokenIdFromEvent, "Demo: reminted tokenId mismatch");
        require(
            IERC721(address(POSITION_MANAGER)).ownerOf(newTokenId) == address(deployment.vault),
            "Demo: vault should own reminted NFT"
        );
        require(deployment.vault.ownerOf(newTokenId) == owner, "Demo: loan owner should remain unchanged");

        (, PositionInfo newPositionInfo) = POSITION_MANAGER.getPoolAndPositionInfo(newTokenId);
        LoanSnapshot memory afterRange = _loanSnapshot(deployment.vault, newTokenId);

        require(
            newPositionInfo.tickLower() != oldPositionInfo.tickLower()
                || newPositionInfo.tickUpper() != oldPositionInfo.tickUpper(),
            "Demo: range did not change"
        );
        require(afterRange.debt == before.debt, "Demo: debt should migrate across auto-range");
        _assertPositionConfigEq(deployment.revertHook, newTokenId, expectedConfig);

        console.log("AUTO_RANGE executed.");
        console.log("  old tokenId:", tokenId);
        console.log("  new tokenId:", newTokenId);
        console.log("  old range lower:", int256(oldPositionInfo.tickLower()));
        console.log("  old range upper:", int256(oldPositionInfo.tickUpper()));
        console.log("  new range lower:", int256(newPositionInfo.tickLower()));
        console.log("  new range upper:", int256(newPositionInfo.tickUpper()));
        console.log("  current tick:", int256(_currentTick(deployment.poolKey)));
        console.log("  loan owner preserved:", deployment.vault.ownerOf(newTokenId));
        _logLoanState("Loan after range remint", afterRange);
    }

    function _runAutoExitPhase(
        DeploymentResult memory deployment,
        uint256 tokenId,
        RevertHookState.PositionConfig memory expectedConfig
    ) internal returns (uint256 exitedTokenId) {
        exitedTokenId = tokenId;
        _logSection("5. Push price downward until AUTO_EXIT unwinds the reminted position");
        _assertPositionConfigEq(deployment.revertHook, tokenId, expectedConfig);

        (bool lowerIncreasing, uint32 lowerSize, int24 lowerHead) =
            deployment.revertHook.lowerTriggerAfterSwap(deployment.poolKey.toId());
        (, PositionInfo positionInfo) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        uint256 maxSteps = vm.envOr("DEMO_MAX_EXIT_STEPS", uint256(16));
        uint128 amountInPerStep = uint128(vm.envOr("DEMO_EXIT_SWAP_STEP_AMOUNT", uint256(0.03 ether)));
        int24 exitLowerTrigger = positionInfo.tickLower() - expectedConfig.autoExitTickLower;

        console.log("Starting tokenId for exit phase:", tokenId);
        console.log("Current tick:", int256(_currentTick(deployment.poolKey)));
        console.log("Current lower range edge:", int256(positionInfo.tickLower()));
        console.log("Exit lower trigger:", int256(exitLowerTrigger));
        console.log("Lower list increasing:", lowerIncreasing);
        console.log("Lower list size:", uint256(lowerSize));
        console.log("Lower list head:", int256(lowerHead));
        console.log(
            "Cursor before exit phase:", int256(deployment.revertHook.tickLowerLasts(deployment.poolKey.toId()))
        );
        console.log("The reminted position keeps the migrated automation config.");
        console.log(
            "On the way back down, the lower AUTO_EXIT trigger sits above the lower leverage and range triggers."
        );
        console.log("So the next crossed lower trigger should unwind the position before anything else.");

        vm.recordLogs();

        bool triggered;
        for (uint256 step; step < maxSteps; ++step) {
            int24 tickBefore = _currentTick(deployment.poolKey);
            _logSwapStep("Exit hunt", step + 1, tickBefore, amountInPerStep, true);
            _swapExactInputSingle(deployment.poolKey, true, amountInPerStep);

            int24 tickAfter = _currentTick(deployment.poolKey);
            console.log("  tick after:", int256(tickAfter));
            (, lowerSize, lowerHead) = deployment.revertHook.lowerTriggerAfterSwap(deployment.poolKey.toId());
            console.log("  cursor after:", int256(deployment.revertHook.tickLowerLasts(deployment.poolKey.toId())));
            console.log("  lower list size after:", uint256(lowerSize));
            console.log("  lower list head after:", int256(lowerHead));

            if (POSITION_MANAGER.getPositionLiquidity(tokenId) == 0) {
                triggered = true;
                break;
            }
        }

        require(triggered, "Demo: AUTO_EXIT did not execute");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (bool sawAutoRange,,) = _findAutoRange(entries, address(deployment.revertHook));
        (bool sawAutoExit, uint256 exitedTokenIdFromEvent) = _findAutoExit(entries, address(deployment.revertHook));
        (bool sawAutoLeverage,,,,) = _findAutoLeverage(entries, address(deployment.revertHook));

        require(sawAutoExit, "Demo: AutoExit event not found");
        require(!sawAutoRange, "Demo: AUTO_RANGE should not fire during exit phase");
        require(!sawAutoLeverage, "Demo: AUTO_LEVERAGE should not fire during exit phase");
        require(exitedTokenIdFromEvent == tokenId, "Demo: unexpected AutoExit token");

        LoanSnapshot memory afterExit = _loanSnapshot(deployment.vault, tokenId);
        (uint8 modeFlags,,,,,,,,,,) = deployment.revertHook.positionConfigs(tokenId);

        require(POSITION_MANAGER.getPositionLiquidity(tokenId) == 0, "Demo: exited position should have no liquidity");
        require(modeFlags == PositionModeFlags.MODE_NONE, "Demo: AUTO_EXIT should disable the position");
        require(afterExit.debt == 0, "Demo: AUTO_EXIT should fully repay debt");

        console.log("AUTO_EXIT executed.");
        console.log("  exited tokenId:", tokenId);
        console.log("  current tick:", int256(_currentTick(deployment.poolKey)));
        _logLoanState("Loan after AUTO_EXIT", afterExit);
    }

    function _approveAll(DeploymentResult memory deployment, address owner) internal {
        IERC20(address(deployment.demoUsd)).approve(address(PERMIT2), type(uint256).max);
        IERC20(address(deployment.demoEth)).approve(address(PERMIT2), type(uint256).max);

        PERMIT2.approve(address(deployment.demoUsd), address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(deployment.demoEth), address(POSITION_MANAGER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(deployment.demoUsd), address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);
        PERMIT2.approve(address(deployment.demoEth), address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);
        IERC721(address(POSITION_MANAGER)).setApprovalForAll(address(deployment.revertHook), true);

        require(deployment.demoUsd.balanceOf(owner) > 0, "Demo: missing demoUsd");
        require(deployment.demoEth.balanceOf(owner) > 0, "Demo: missing demoEth");
    }

    function _initializePool(PoolKey memory poolKey) internal {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(POSITION_MANAGER.poolManager(), poolKey.toId());
        if (sqrtPriceX96 == 0) {
            POSITION_MANAGER.poolManager().initialize(poolKey, uint160(2 ** 96));
        }
    }

    function _swapExactInputSingle(PoolKey memory poolKey, bool zeroForOne, uint128 amountIn) internal {
        bytes memory commands = hex"10";
        bytes[] memory inputs = new bytes[](1);
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey, zeroForOne: zeroForOne, amountIn: amountIn, amountOutMinimum: 0, hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? poolKey.currency0 : poolKey.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? poolKey.currency1 : poolKey.currency0, 0);
        inputs[0] = abi.encode(actions, params);

        UNIVERSAL_ROUTER.execute(commands, inputs, _deadline());
    }

    function _buildHookedPoolKey(address tokenA, address tokenB, address hook) internal pure returns (PoolKey memory) {
        if (tokenA < tokenB) {
            return PoolKey({
                currency0: Currency.wrap(tokenA),
                currency1: Currency.wrap(tokenB),
                fee: 3000,
                tickSpacing: 60,
                hooks: IHooks(hook)
            });
        }

        return PoolKey({
            currency0: Currency.wrap(tokenB),
            currency1: Currency.wrap(tokenA),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function _currentTick(PoolKey memory poolKey) internal view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(POSITION_MANAGER.poolManager(), poolKey.toId());
    }

    function _poolTickSpacing(uint256 tokenId) internal view returns (int24 tickSpacing) {
        (PoolKey memory poolKey,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        return poolKey.tickSpacing;
    }

    function _rangeUpperTrigger(uint256 tokenId, RevertHook hook) internal view returns (int24) {
        (, PositionInfo positionInfo) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        (
            uint8 modeFlags,
            RevertHookState.AutoCollectMode autoCollectMode,
            bool autoExitIsRelative,
            int24 autoExitTickLower,
            int24 autoExitTickUpper,
            int24 autoRangeLowerLimit,
            int24 autoRangeUpperLimit,
            int24 autoRangeLowerDelta,
            int24 autoRangeUpperDelta,
            int24 autoLendToleranceTick,
            uint16 autoLeverageTargetBps
        ) = hook.positionConfigs(tokenId);

        modeFlags;
        autoCollectMode;
        autoExitIsRelative;
        autoExitTickLower;
        autoExitTickUpper;
        autoRangeLowerLimit;
        autoRangeLowerDelta;
        autoRangeUpperDelta;
        autoLendToleranceTick;
        autoLeverageTargetBps;

        if (autoRangeUpperLimit == type(int24).max) {
            return type(int24).max;
        }

        return positionInfo.tickUpper() + autoRangeUpperLimit;
    }

    function _loanSnapshot(V4Vault vault, uint256 tokenId) internal view returns (LoanSnapshot memory snapshot) {
        (snapshot.debt, snapshot.fullValue, snapshot.collateralValue,,) = vault.loanInfo(tokenId);
    }

    function _autoLeverageBaseTick(RevertHook hook, uint256 tokenId)
        internal
        view
        returns (int24 autoLeverageBaseTick)
    {
        (,,,,,,, autoLeverageBaseTick) = hook.positionStates(tokenId);
    }

    function _ratioBps(uint256 debt, uint256 collateralValue) internal pure returns (uint256) {
        if (collateralValue == 0) {
            return 0;
        }
        return debt * 10_000 / collateralValue;
    }

    function _logBanner(string memory title) internal pure {
        console.log("");
        console.log("============================================================");
        console.log(title);
        console.log("============================================================");
    }

    function _logSection(string memory title) internal pure {
        console.log("");
        console.log("------------------------------------------------------------");
        console.log(title);
        console.log("------------------------------------------------------------");
    }

    function _logLoanState(string memory title, LoanSnapshot memory snapshot) internal pure {
        console.log(title);
        console.log("  debt:", snapshot.debt);
        console.log("  full value:", snapshot.fullValue);
        console.log("  collateral value:", snapshot.collateralValue);
        console.log("  debt ratio bps:", _ratioBps(snapshot.debt, snapshot.collateralValue));
    }

    function _logTriggerPlan(RevertHook hook, uint256 tokenId, RevertHookState.PositionConfig memory config)
        internal
        view
    {
        (, PositionInfo positionInfo) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        int24 spacing = _poolTickSpacing(tokenId);
        int24 baseTick = _autoLeverageBaseTick(hook, tokenId);
        int24 leverageUpper = baseTick + 10 * spacing;
        int24 leverageLower = baseTick - 10 * spacing;
        int24 rangeUpper = positionInfo.tickUpper() + config.autoRangeUpperLimit;
        int24 rangeLower = config.autoRangeLowerLimit == type(int24).min
            ? type(int24).min
            : positionInfo.tickLower() - config.autoRangeLowerLimit;
        int24 exitLower = config.autoExitTickLower == type(int24).min
            ? type(int24).min
            : positionInfo.tickLower() - config.autoExitTickLower;

        console.log("Leverage, range, and lower-side exit are now active on the same vault-backed position.");
        console.log("  leverage target bps:", uint256(config.autoLeverageTargetBps));
        console.log("  current base tick:", int256(baseTick));
        console.log("  first leverage lower trigger:", int256(leverageLower));
        console.log("  first leverage upper trigger:", int256(leverageUpper));
        console.log("  lower exit trigger:", int256(exitLower));
        console.log("  range lower trigger:", int256(rangeLower));
        console.log("  range upper trigger:", int256(rangeUpper));
        console.log("The config step already rebalanced leverage immediately.");
        console.log("Next we cross the upper range trigger, remint with AUTO_RANGE, then come back down for AUTO_EXIT.");
    }

    function _logSwapStep(string memory label, uint256 step, int24 currentTick, uint128 amountIn, bool zeroForOne)
        internal
        pure
    {
        console.log(label);
        console.log("  step:", step);
        console.log("  tick before:", int256(currentTick));
        console.log("  amount in:", uint256(amountIn));
        console.log("  direction zeroForOne:", zeroForOne);
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + vm.envOr("DEMO_DEADLINE_BUFFER", uint256(1 hours));
    }

    function _assertPositionConfigEq(RevertHook hook, uint256 tokenId, RevertHookState.PositionConfig memory expected)
        internal
        view
    {
        (
            uint8 modeFlags,
            RevertHookState.AutoCollectMode autoCollectMode,
            bool autoExitIsRelative,
            int24 autoExitTickLower,
            int24 autoExitTickUpper,
            int24 autoRangeLowerLimit,
            int24 autoRangeUpperLimit,
            int24 autoRangeLowerDelta,
            int24 autoRangeUpperDelta,
            int24 autoLendToleranceTick,
            uint16 autoLeverageTargetBps
        ) = hook.positionConfigs(tokenId);

        require(modeFlags == expected.modeFlags, "Demo: mode flags mismatch");
        require(uint8(autoCollectMode) == uint8(expected.autoCollectMode), "Demo: auto compound mode mismatch");
        require(autoExitIsRelative == expected.autoExitIsRelative, "Demo: auto exit mode mismatch");
        require(autoExitTickLower == expected.autoExitTickLower, "Demo: auto exit lower mismatch");
        require(autoExitTickUpper == expected.autoExitTickUpper, "Demo: auto exit upper mismatch");
        require(autoRangeLowerLimit == expected.autoRangeLowerLimit, "Demo: auto range lower limit mismatch");
        require(autoRangeUpperLimit == expected.autoRangeUpperLimit, "Demo: auto range upper limit mismatch");
        require(autoRangeLowerDelta == expected.autoRangeLowerDelta, "Demo: auto range lower delta mismatch");
        require(autoRangeUpperDelta == expected.autoRangeUpperDelta, "Demo: auto range upper delta mismatch");
        require(autoLendToleranceTick == expected.autoLendToleranceTick, "Demo: auto lend tolerance mismatch");
        require(autoLeverageTargetBps == expected.autoLeverageTargetBps, "Demo: auto leverage target mismatch");
    }

    function _findAutoRange(Vm.Log[] memory entries, address emitter)
        internal
        pure
        returns (bool sawAutoRangeEvent, uint256 tokenId, uint256 newTokenId)
    {
        uint256 length = entries.length;
        for (uint256 i; i < length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != emitter) {
                continue;
            }
            if (entry.topics.length == 0 || entry.topics[0] != AUTO_RANGE_TOPIC) {
                continue;
            }

            sawAutoRangeEvent = true;
            tokenId = uint256(entry.topics[1]);
            (newTokenId,,,,) = abi.decode(entry.data, (uint256, address, address, uint256, uint256));
            return (sawAutoRangeEvent, tokenId, newTokenId);
        }
    }

    function _findAutoLeverage(Vm.Log[] memory entries, address emitter)
        internal
        pure
        returns (bool sawAutoLeverageEvent, uint256 tokenId, bool isUpperTrigger, uint256 debtBefore, uint256 debtAfter)
    {
        uint256 length = entries.length;
        for (uint256 i; i < length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != emitter) {
                continue;
            }
            if (entry.topics.length == 0 || entry.topics[0] != AUTO_LEVERAGE_TOPIC) {
                continue;
            }

            sawAutoLeverageEvent = true;
            tokenId = uint256(entry.topics[1]);
            (isUpperTrigger, debtBefore, debtAfter) = abi.decode(entry.data, (bool, uint256, uint256));
            return (sawAutoLeverageEvent, tokenId, isUpperTrigger, debtBefore, debtAfter);
        }
    }

    function _findAutoExit(Vm.Log[] memory entries, address emitter)
        internal
        pure
        returns (bool sawAutoExitEvent, uint256 tokenId)
    {
        uint256 length = entries.length;
        for (uint256 i; i < length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != emitter) {
                continue;
            }
            if (entry.topics.length == 0 || entry.topics[0] != AUTO_EXIT_TOPIC) {
                continue;
            }

            sawAutoExitEvent = true;
            tokenId = uint256(entry.topics[1]);
            return (sawAutoExitEvent, tokenId);
        }
    }

    function getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

    function findHookSalt(address deployer, bytes memory creationCodeWithArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        uint160 flags = getHookFlags() & Hooks.ALL_HOOK_MASK;

        for (uint256 i; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hookAddress = computeCreate2Address(deployer, salt, creationCodeWithArgs);

            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, salt);
            }
        }

        revert("Demo: could not find valid hook salt");
    }

    function computeCreate2Address(address deployer, bytes32 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }
}
