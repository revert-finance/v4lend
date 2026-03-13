// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
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
import {RevertHookPositionActions} from "src/hook/RevertHookPositionActions.sol";
import {RevertHookAutoLeverageActions} from "src/hook/RevertHookAutoLeverageActions.sol";
import {RevertHookAutoLendActions} from "src/hook/RevertHookAutoLendActions.sol";
import {PositionModeFlags} from "src/hook/lib/PositionModeFlags.sol";

import {DemoERC20} from "./support/DemoERC20.sol";
import {MockAggregatorV3} from "./support/MockAggregatorV3.sol";

contract UnichainForkHookathonE2E is Script, StdCheats {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q32 = 2 ** 32;
    uint256 internal constant Q64 = 2 ** 64;

    IPositionManager internal constant POSITION_MANAGER =
        IPositionManager(0x4529A01c7A0410167c5740C487A8DE60232617bf);
    IUniversalRouter internal constant UNIVERSAL_ROUTER =
        IUniversalRouter(0xEf740bf23aCaE26f6492B10de645D6B98dC8Eaf3);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
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

    bytes32 internal constant AUTO_RANGE_TOPIC =
        keccak256("AutoRange(uint256,uint256,address,address,uint256,uint256)");

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

    function run() external {
        string memory rpcUrl = vm.envOr("UNICHAIN_RPC_URL", string("https://mainnet.unichain.org"));
        vm.createSelectFork(rpcUrl);

        uint256 deployerPrivateKey = vm.envOr("DEMO_PRIVATE_KEY", uint256(1));
        address deployer = vm.addr(deployerPrivateKey);
        vm.deal(deployer, 100 ether);

        console.log("== Unichain fork hookathon e2e demo ==");
        console.log("Fork RPC:", rpcUrl);
        console.log("Deployer:", deployer);

        vm.startPrank(deployer);

        DeploymentResult memory deployment = _deployAll(deployer);
        uint256 ambientTokenId = _mintAmbientPosition(deployment, deployer);
        uint256 tokenId = _mintHookedPosition(deployment, deployer);
        _configureAutoRange(deployment.revertHook, tokenId);
        _swapAndVerify(deployment, tokenId, deployer);

        vm.stopPrank();

        console.log("Demo completed successfully.");
        console.log("Hook:", address(deployment.revertHook));
        console.log("Vault:", address(deployment.vault));
        console.log("Ambient tokenId:", ambientTokenId);
        console.log("Initial tokenId:", tokenId);
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

        deployment.positionActions =
            new RevertHookPositionActions(PERMIT2, deployment.oracle, ILiquidityCalculator(deployment.liquidityCalculator));
        deployment.autoLeverageActions =
            new RevertHookAutoLeverageActions(PERMIT2, deployment.oracle, ILiquidityCalculator(deployment.liquidityCalculator));
        deployment.autoLendActions =
            new RevertHookAutoLendActions(PERMIT2, deployment.oracle, ILiquidityCalculator(deployment.liquidityCalculator));

        bytes memory constructorArgs = abi.encode(
            deployer,
            deployer,
            PERMIT2,
            deployment.oracle,
            ILiquidityCalculator(deployment.liquidityCalculator),
            deployment.positionActions,
            deployment.autoLeverageActions,
            deployment.autoLendActions
        );
        address hookAddress = address(uint160(getHookFlags()) ^ (uint160(0x484f) << 144));
        deployCodeTo("RevertHook.sol:RevertHook", constructorArgs, hookAddress);
        deployment.revertHook = RevertHook(payable(hookAddress));
        deployment.revertHook.setProtocolFeeBps(PROTOCOL_FEE_BPS);
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
        deployment.vault.setLimits(
            MIN_LOAN_SIZE,
            GLOBAL_LEND_LIMIT,
            GLOBAL_DEBT_LIMIT,
            DAILY_LEND_INCREASE_LIMIT_MIN,
            DAILY_DEBT_INCREASE_LIMIT_MIN
        );
        deployment.vault.setReserveFactor(uint32(Q32 * 10 / 100));
        deployment.vault.setReserveProtectionFactor(uint32(Q32 * 5 / 100));

        deployment.flashloanLiquidator = new FlashloanLiquidator(POSITION_MANAGER, address(UNIVERSAL_ROUTER), address(0));
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

        deployment.poolKey = _buildHookedPoolKey(address(deployment.demoUsd), address(deployment.demoEth), address(deployment.revertHook));
        _initializePool(deployment.poolKey);
        _approveAll(deployment, deployer);

        console.log("Deployed hook:", address(deployment.revertHook));
        console.log("Deployed vault:", address(deployment.vault));
        console.log("Pool token0:", Currency.unwrap(deployment.poolKey.currency0));
        console.log("Pool token1:", Currency.unwrap(deployment.poolKey.currency1));
    }

    function _mintHookedPosition(DeploymentResult memory deployment, address owner) internal returns (uint256 tokenId) {
        int24 tickLower = int24(vm.envOr("DEMO_TICK_LOWER", int256(-60)));
        int24 tickUpper = int24(vm.envOr("DEMO_TICK_UPPER", int256(60)));
        uint128 liquidity = uint128(vm.envOr("DEMO_POSITION_LIQUIDITY", uint256(5e18)));

        tokenId = _mintPosition(deployment, owner, tickLower, tickUpper, liquidity, "hooked");
    }

    function _mintAmbientPosition(DeploymentResult memory deployment, address owner) internal returns (uint256 tokenId) {
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
            deployment.poolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            owner,
            bytes("")
        );
        paramsArray[1] = abi.encode(deployment.poolKey.currency0, deployment.poolKey.currency1, owner);

        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, paramsArray), block.timestamp);
        tokenId = POSITION_MANAGER.nextTokenId() - 1;
        require(tokenId >= nextTokenIdBefore, "Demo: position mint failed");

        console.log("Minted", label, "tokenId:", tokenId);
        console.log("Minted tickLower:", int256(tickLower));
        console.log("Minted tickUpper:", int256(tickUpper));
    }

    function _configureAutoRange(RevertHook hook, uint256 tokenId) internal {
        hook.setGeneralConfig(tokenId, 0, 0, IHooks(address(0)), 100, 100);
        hook.setPositionConfig(
            tokenId,
            RevertHookState.PositionConfig({
                modeFlags: PositionModeFlags.MODE_AUTO_RANGE,
                autoCompoundMode: RevertHookState.AutoCompoundMode.NONE,
                autoExitIsRelative: false,
                autoExitTickLower: type(int24).min,
                autoExitTickUpper: type(int24).max,
                autoRangeLowerLimit: 0,
                autoRangeUpperLimit: 0,
                autoRangeLowerDelta: -60,
                autoRangeUpperDelta: 60,
                autoLendToleranceTick: 0,
                autoLeverageTargetBps: 0
            })
        );
        console.log("Configured AutoRange for tokenId:", tokenId);
    }

    function _swapAndVerify(DeploymentResult memory deployment, uint256 tokenId, address owner) internal {
        (, PositionInfo oldPositionInfo) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();
        uint256 maxSwapSteps = vm.envOr("MAX_SWAP_STEPS", uint256(16));

        vm.recordLogs();

        bool triggered;
        for (uint256 step; step < maxSwapSteps; ++step) {
            int24 currentTickBefore = _currentTick(deployment.poolKey);
            uint128 amountInPerStep = _nextSwapAmount(currentTickBefore, oldPositionInfo.tickLower());

            console.log("Swap step:", step + 1);
            console.log("Tick before:", int256(currentTickBefore));
            console.log("Amount in:", uint256(amountInPerStep));

            _swapExactInputSingle(deployment.poolKey, true, amountInPerStep);

            int24 currentTickAfter = _currentTick(deployment.poolKey);
            console.log("Tick after:", int256(currentTickAfter));

            if (POSITION_MANAGER.nextTokenId() > nextTokenIdBefore) {
                triggered = true;
                break;
            }
        }

        require(triggered, "Demo: hook did not remint the position");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        (bool sawAutoRangeEvent, uint256 eventTokenId, uint256 newTokenIdFromEvent) = _findAutoRange(entries);

        require(sawAutoRangeEvent, "Demo: AutoRange event not found");
        require(eventTokenId == tokenId, "Demo: unexpected AutoRange tokenId");

        uint256 newTokenId = POSITION_MANAGER.nextTokenId() - 1;
        require(newTokenId == newTokenIdFromEvent, "Demo: reminted tokenId mismatch");
        require(IERC721(address(POSITION_MANAGER)).ownerOf(newTokenId) == owner, "Demo: wrong new owner");

        (, PositionInfo newPositionInfo) = POSITION_MANAGER.getPoolAndPositionInfo(newTokenId);
        require(
            newPositionInfo.tickLower() != oldPositionInfo.tickLower()
                || newPositionInfo.tickUpper() != oldPositionInfo.tickUpper(),
            "Demo: range did not change"
        );

        (uint8 modeFlags,,,,,,,,,,) = deployment.revertHook.positionConfigs(newTokenId);
        require(modeFlags == PositionModeFlags.MODE_AUTO_RANGE, "Demo: config did not migrate");

        console.log("AutoRange executed.");
        console.log("Old tokenId:", tokenId);
        console.log("New tokenId:", newTokenId);
        console.log("Old tickLower:", int256(oldPositionInfo.tickLower()));
        console.log("Old tickUpper:", int256(oldPositionInfo.tickUpper()));
        console.log("New tickLower:", int256(newPositionInfo.tickLower()));
        console.log("New tickUpper:", int256(newPositionInfo.tickUpper()));
        console.log("Current tick:", int256(_currentTick(deployment.poolKey)));
    }

    function _nextSwapAmount(int24 currentTick, int24 targetLowerTick) internal view returns (uint128 amountIn) {
        if (currentTick <= targetLowerTick) {
            return uint128(vm.envOr("SWAP_STEP_AMOUNT_FINAL", uint256(0.0002 ether)));
        }

        int24 distance = currentTick - targetLowerTick;
        if (distance > 30) {
            return uint128(vm.envOr("SWAP_STEP_AMOUNT_FAR", uint256(0.002 ether)));
        }
        if (distance > 10) {
            return uint128(vm.envOr("SWAP_STEP_AMOUNT_MID", uint256(0.001 ether)));
        }
        return uint128(vm.envOr("SWAP_STEP_AMOUNT_CLOSE", uint256(0.0005 ether)));
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
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(zeroForOne ? poolKey.currency0 : poolKey.currency1, amountIn);
        params[2] = abi.encode(zeroForOne ? poolKey.currency1 : poolKey.currency0, 0);
        inputs[0] = abi.encode(actions, params);

        UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp);
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

    function _findAutoRange(Vm.Log[] memory entries)
        internal
        pure
        returns (bool sawAutoRangeEvent, uint256 tokenId, uint256 newTokenId)
    {
        uint256 length = entries.length;
        for (uint256 i; i < length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.topics.length == 0 || entry.topics[0] != AUTO_RANGE_TOPIC) {
                continue;
            }

            sawAutoRangeEvent = true;
            tokenId = uint256(entry.topics[1]);
            (newTokenId,, , ,) = abi.decode(entry.data, (uint256, address, address, uint256, uint256));
            return (sawAutoRangeEvent, tokenId, newTokenId);
        }
    }

    function getHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

}
