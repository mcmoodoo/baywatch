// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { ISwapVM } from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import { TakerTraitsLib } from "@1inch/swap-vm/src/libs/TakerTraits.sol";

import { SharedAquaRouter } from "../src/routers/SharedAquaRouter.sol";
import { LpStrategy } from "../src/LpStrategy.sol";
import { MockTaker } from "./utils/MockTaker.sol";
import { dynamic } from "./utils/Dynamic.sol";

/// @dev The smallest thing that could stand in for an ERC-4626 vault as the Aqua maker: it holds the
///      pooled inventory, approves Aqua, and ships the order. Notably it has NO swap-time code — because
///      our order sets every maker hook to false, the maker is passive during a swap (Aqua pulls tokenOut
///      from and pushes tokenIn to this contract's own wallet). A real vault adds ERC-4626 share
///      accounting + deposit/withdraw lifecycle on top of exactly this.
contract MinimalLpVault {
    Aqua public immutable AQUA;

    constructor(Aqua aqua) { AQUA = aqua; }

    function approveAqua(address token) external {
        IERC20(token).approve(address(AQUA), type(uint256).max);
    }

    function ship(address app, bytes calldata strategy, address[] calldata tokens, uint256[] calldata amounts)
        external
        returns (bytes32)
    {
        return AQUA.ship(app, strategy, tokens, amounts);
    }
}

/// @notice Verifies the load-bearing claim behind the LP-vault direction: a plain CONTRACT (not an EOA) can be
///         the Aqua maker, so one vault can provide liquidity to Aqua on behalf of many LPs instead of
///         individual market makers each shipping their own. Also shows the vault captures the maker
///         spread as PnL (the LP yield) and that Aqua is non-custodial (funds live in the vault's wallet).
contract VaultMakerTest is Test {
    uint256 constant INIT_A = 1000e18;
    uint256 constant INIT_B = 2000e18;
    uint256 constant SWAP_AMOUNT = 100e18;
    uint32  constant SPREAD_BPS = 3_000_000; // 0.3% of BPS=1e9

    Aqua aqua;
    SharedAquaRouter router;
    LpStrategy lp;
    TokenMock tokenA;
    TokenMock tokenB;
    MockTaker taker;
    MinimalLpVault vault;

    function setUp() public {
        aqua = new Aqua();
        router = new SharedAquaRouter(address(aqua), address(0), address(this), "SharedAquaVM", "1.0.0");
        lp = new LpStrategy(address(aqua));
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        taker = new MockTaker(aqua, router, address(this));
        vault = new MinimalLpVault(aqua);
    }

    function _takerData() internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(taker),
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: address(0),
            deadline: 0,
            hasPreTransferInCallback: true,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: ""
        }));
    }

    /// @dev Ship pooled inventory FROM the vault contract: the vault (msg.sender) becomes the Aqua maker.
    function _shipFromVault(bytes memory program) internal returns (ISwapVM.Order memory order, bytes32 orderHash) {
        order = lp.createOrder(address(vault), program);
        orderHash = router.hash(order);

        tokenA.mint(address(vault), INIT_A);
        tokenB.mint(address(vault), INIT_B);
        vault.approveAqua(address(tokenA));
        vault.approveAqua(address(tokenB));

        bytes32 strategyHash = vault.ship(
            address(router),
            abi.encode(order),
            dynamic([address(tokenA), address(tokenB)]),
            dynamic([INIT_A, INIT_B])
        );
        assertEq(strategyHash, orderHash, "vault shipped: strategyHash == orderHash");
    }

    /// A contract can be the Aqua maker, and a swap settles against it exactly like an EOA maker —
    /// with the tokens moving in/out of the VAULT'S OWN WALLET (Aqua is non-custodial accounting).
    function test_contractCanBeAquaMaker() public {
        bytes memory program = lp.buildXYCProgram(uint64(uint256(keccak256("vault-xyc"))));
        (ISwapVM.Order memory order, bytes32 orderHash) = _shipFromVault(program);

        tokenA.mint(address(taker), SWAP_AMOUNT);

        uint256 vaultA0 = tokenA.balanceOf(address(vault));
        uint256 vaultB0 = tokenB.balanceOf(address(vault));
        uint256 takerB0 = tokenB.balanceOf(address(taker));
        (uint256 mA0, uint256 mB0) = aqua.safeBalances(address(vault), address(router), orderHash, address(tokenA), address(tokenB));

        (uint256 amountIn, uint256 amountOut) = taker.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, _takerData());

        // Taker got real output.
        assertEq(amountIn, SWAP_AMOUNT, "exact-in");
        assertGt(amountOut, 0, "produced output");
        assertEq(tokenB.balanceOf(address(taker)) - takerB0, amountOut, "taker received tokenB");

        // Non-custodial: the tokens moved in/out of the VAULT's own ERC-20 balance.
        assertEq(tokenA.balanceOf(address(vault)) - vaultA0, amountIn, "vault wallet received tokenIn");
        assertEq(vaultB0 - tokenB.balanceOf(address(vault)), amountOut, "vault wallet sent tokenOut");

        // Aqua's internal maker accounting tracked it against the vault as maker.
        (uint256 mA1, uint256 mB1) = aqua.safeBalances(address(vault), address(router), orderHash, address(tokenA), address(tokenB));
        assertEq(mA1 - mA0, amountIn, "aqua maker reserve A += in");
        assertEq(mB0 - mB1, amountOut, "aqua maker reserve B -= out");

        console2.log("vault-as-maker swap: in/out", amountIn, amountOut);
    }

    /// The vault captures the maker spread as PnL: after a taker round-trips A->B->A, the taker ends with
    /// LESS tokenA than it started, and that difference is now inventory the vault holds for its LPs.
    function test_vaultAccruesSpreadAsLpYield() public {
        // oracle == address(0) => _loadParamsXD fails safe to a fixed maxSpread (0.3%) on every swap.
        bytes memory program = lp.buildAdaptiveXYCProgram(address(0), 300, SPREAD_BPS, uint64(uint256(keccak256("vault-spread"))));
        (ISwapVM.Order memory order,) = _shipFromVault(program);

        tokenA.mint(address(taker), SWAP_AMOUNT);
        uint256 takerA_start = tokenA.balanceOf(address(taker));

        // Leg 1: A -> B
        taker.swap(order, address(tokenA), address(tokenB), SWAP_AMOUNT, _takerData());
        uint256 gotB = tokenB.balanceOf(address(taker));
        assertGt(gotB, 0, "leg1 produced B");

        // Leg 2: B -> A (swap the whole B balance back)
        taker.swap(order, address(tokenB), address(tokenA), gotB, _takerData());

        uint256 takerA_end = tokenA.balanceOf(address(taker));
        assertEq(tokenB.balanceOf(address(taker)), 0, "taker unwound all B");

        // Taker's round-trip loss == the spread the vault kept for its LPs.
        assertLt(takerA_end, takerA_start, "round-trip taker lost value to the vault");
        uint256 lpProfit = takerA_start - takerA_end;
        assertGt(lpProfit, 0, "vault captured spread");
        console2.log("LP yield captured by vault (tokenA units):", lpProfit);
    }
}
