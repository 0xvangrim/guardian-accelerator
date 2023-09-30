// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployPerpetuEx} from "../../script/DeployPerpetuEx.sol";
import {PerpetuEx} from "../../src/PerpetuEx.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPerpetuEx} from "../../src/IPerpetuEx.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);

    function mint(address to, uint256 amount) external;

    function configureMinter(address minter, uint256 minterAllowedAmount) external;

    function masterMinter() external view returns (address);

    function approve(address spender, uint256 amount) external returns (bool);
}

contract PerpetuExTest is Test, IPerpetuEx {
    PerpetuEx public perpetuEx;
    HelperConfig public helperConfig;
    DeployPerpetuEx public deployer;
    address public priceFeed;
    address public constant USER = address(21312312312312312312);
    address public constant USER2 = address(456654456654456654546);
    // create a liquidity provider account
    address public constant LP = address(123123123123123123123);

    // USDC contract address on mainnet
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // User mock params
    uint256 SIZE = 1;
    uint256 SIZE_2 = 2;
    uint256 COLLATERAL = 10000e6; // sufficient collateral to open a position with size 1
    uint256 DECREASE_COLLATERAL = 1500e6;

    // LP mock params
    uint256 LIQUIDITY = 1000000e6;

    uint256 private constant MAX_UTILIZATION_PERCENTAGE = 80; //80%
    uint256 private constant MAX_UTILIZATION_PERCENTAGE_DECIMALS = 100;
    uint256 private constant SECONDS_PER_YEAR = 31536000; // 365 * 24 * 60 * 60

    // Dead shares
    uint256 DEAD_SHARES = 1000;

    function setUp() external {
        // spoof .configureMinter() call with the master minter account
        vm.prank(IUSDC(usdc).masterMinter());
        // allow this test contract to mint USDC
        IUSDC(usdc).configureMinter(address(this), type(uint256).max);
        // mint max to the test contract (or an external user)
        IUSDC(usdc).mint(USER, COLLATERAL);
        IUSDC(usdc).mint(USER2, COLLATERAL);
        // mint max to the LP account
        IUSDC(usdc).mint(LP, LIQUIDITY);
        deployer = new DeployPerpetuEx();
        (perpetuEx, helperConfig) = deployer.run();
        (priceFeed,) = helperConfig.activeNetworkConfig();

        vm.prank(USER);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        vm.prank(USER2);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        vm.prank(LP);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
    }

    ///////////////////////////////////////////////////
    /////////////////// MODIFIERS ////////////////////
    /////////////////////////////////////////////////

    modifier addLiquidity(uint256 amount) {
        vm.startPrank(LP);
        // approve the PerpetuEx contract to spend USDC
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        perpetuEx.deposit(amount, LP);
        vm.stopPrank();
        _;
    }

    modifier addCollateral(uint256 amount) {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(amount);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralOpenLongPosition(uint256 amount) {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(amount);
        perpetuEx.createPosition(SIZE, true);
        vm.stopPrank();
        _;
    }

    modifier longPositionOpened(uint256 liquidity, uint256 amount, uint256 size) {
        vm.startPrank(LP);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        perpetuEx.deposit(liquidity, LP);
        vm.stopPrank();
        vm.startPrank(USER);
        perpetuEx.depositCollateral(amount);
        perpetuEx.createPosition(size, true);
        vm.stopPrank();
        _;
    }

    //@dev this mimics the share calculation behavior in ERC4626
    function shareCalculation(uint256 assets) public view returns (uint256 withdrawShares) {
        withdrawShares =
            Math.mulDiv(assets, perpetuEx.totalSupply() + 10 ** 0, perpetuEx.totalAssets() + 1, Math.Rounding.Floor);
    }

    ///////////////////////////////////////////////////
    ////////////// LUIQUIDITY PROVIDERS ///////////////
    ///////////////////////////////////////////////////

    function testBalance() public {
        uint256 balance = IERC20(usdc).balanceOf(USER);
        assertEq(balance, COLLATERAL);

        uint256 LpBalance = IERC20(usdc).balanceOf(LP);
        assertEq(LpBalance, LIQUIDITY);
    }

    //@func depositCollateral
    function testDepositCollateral() public {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(COLLATERAL);
        vm.stopPrank();
        assertEq(perpetuEx.collateral(USER), COLLATERAL);
        assertEq(IERC20(usdc).balanceOf(USER), 0);
    }

    //@func withdrawCollateral
    function testWithdrawCollateral() public {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(COLLATERAL);
        perpetuEx.withdrawCollateral();
        vm.stopPrank();
        assertEq(perpetuEx.collateral(USER), 0);
        assertEq(IERC20(usdc).balanceOf(USER), COLLATERAL);
    }

    function testWithdrawCollateralInsufficient() public {
        vm.expectRevert();
        vm.startPrank(USER);
        perpetuEx.withdrawCollateral();
        vm.stopPrank();
        assertEq(perpetuEx.collateral(USER), 0);
    }

    //@func deposit
    function testDeposit() public {
        vm.startPrank(LP);
        uint256 shares = perpetuEx.deposit(LIQUIDITY, LP);
        vm.stopPrank();
        assertEq(perpetuEx.totalAssets(), LIQUIDITY);
        assertEq(perpetuEx.totalSupply(), shares + DEAD_SHARES);
        assertEq(IERC20(usdc).balanceOf(LP), 0);
        assertEq(IERC20(perpetuEx).balanceOf(LP), shares);
    }

    ////@func withdraw

    //Should revert since we are preserving 20% of the liquidity
    function testWithdrawAllLiquidity() public addLiquidity(LIQUIDITY) {
        uint256 allLiquidity = perpetuEx.totalSupply();
        vm.expectRevert();
        vm.startPrank(LP);
        perpetuEx.withdraw(allLiquidity, LP, LP);
        vm.stopPrank();
    }

    function testWithdraw() public addLiquidity(LIQUIDITY) {
        uint256 allAssets = perpetuEx.totalSupply();
        uint256 maxLiquidity =
            allAssets * perpetuEx.getMaxUtilizationPercentage() / perpetuEx.getMaxUtilizationPercentageDecimals();

        uint256 maxLiquidityToWithdraw = perpetuEx.getTotalLiquidityDeposited()
            * perpetuEx.getMaxUtilizationPercentage() / perpetuEx.getMaxUtilizationPercentageDecimals();
        uint256 withdrawShares = shareCalculation(maxLiquidityToWithdraw);

        vm.startPrank(LP);
        perpetuEx.withdraw(maxLiquidityToWithdraw, LP, LP);

        vm.stopPrank();
        assertEq(perpetuEx.totalAssets(), perpetuEx.getTotalLiquidityDeposited());
        assertEq(perpetuEx.totalSupply(), allAssets - withdrawShares);
        assertEq(IERC20(usdc).balanceOf(LP), maxLiquidityToWithdraw);
        assertEq(IERC20(perpetuEx).balanceOf(LP), allAssets - withdrawShares - DEAD_SHARES);
    }

    //@func redeem
    function testRedeem() public addLiquidity(LIQUIDITY) {
        uint256 allAssets = perpetuEx.totalAssets();
        uint256 allSupply = perpetuEx.totalSupply();
        uint256 lpShares = IERC20(perpetuEx).balanceOf(LP);
        uint256 maxRedeemable =
            lpShares * perpetuEx.getMaxUtilizationPercentage() / perpetuEx.getMaxUtilizationPercentageDecimals();

        vm.startPrank(LP);
        perpetuEx.redeem(maxRedeemable, LP, LP);
        vm.stopPrank();
        assertEq(allAssets, perpetuEx.getTotalLiquidityDeposited() + IERC20(usdc).balanceOf(address(LP)));
        assertEq(perpetuEx.totalSupply(), allSupply - maxRedeemable);
        assertEq(IERC20(usdc).balanceOf(LP), allAssets - IERC20(usdc).balanceOf(address(perpetuEx)));
        assertEq(IERC20(perpetuEx).balanceOf(LP), allSupply - maxRedeemable - DEAD_SHARES);
    }

    //@func mint
    function testMint() public {
        vm.startPrank(LP);
        perpetuEx.mint(1000, LP);
        vm.stopPrank();
        assertEq(perpetuEx.totalSupply(), DEAD_SHARES + 1000);
        assertEq(IERC20(perpetuEx).balanceOf(LP), 1000);
    }

    ///////////////////////////////////////////////////
    //////////////////// TRADERS /////////////////////
    //////////////////////////////////////////////////

    /////////////////////
    /// Create Position
    /////////////////////

    function testCreateLongPosition() public addLiquidity(LIQUIDITY) addCollateral(COLLATERAL) {
        vm.startPrank(USER);
        perpetuEx.createPosition(SIZE, true);
        vm.stopPrank();

        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        (bool isLong, uint256 totalValue, uint256 size,,,) = perpetuEx.positions(positionId);

        assert(isLong);
        assertEq(perpetuEx.collateral(USER), COLLATERAL);
        assertEq(size, SIZE);
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        assertEq(longOpenInterestInTokens, SIZE);
        uint256 shortOpenInterest = perpetuEx.s_shortOpenInterest();
        assertEq(shortOpenInterest, 0);
        uint256 averageOpenPrice = perpetuEx.getAverageOpenPrice(positionId);
        assertEq(totalValue, SIZE * averageOpenPrice);
    }

    function testCreateShortPosition() public addLiquidity(LIQUIDITY) addCollateral(COLLATERAL) {
        vm.startPrank(USER);
        perpetuEx.createPosition(SIZE, false);
        vm.stopPrank();

        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        (bool isLong, uint256 totalValue, uint256 size,,,) = perpetuEx.positions(positionId);

        assert(!isLong);
        assertEq(perpetuEx.collateral(USER), COLLATERAL);
        assertEq(size, SIZE);
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        assertEq(longOpenInterestInTokens, 0);
        uint256 shortOpenInterest = perpetuEx.s_shortOpenInterest();
        uint256 averageOpenPrice = perpetuEx.getAverageOpenPrice(positionId);
        assertEq(shortOpenInterest, SIZE * averageOpenPrice);
        assertEq(totalValue, SIZE * averageOpenPrice);
    }

    // forge test --match-test "testOpenLongAndShortPositions" --fork-url ${MAINNET_RPC_URL}  -vvvv
    function testOpenLongAndShortPositions() public addLiquidity(LIQUIDITY) addCollateral(COLLATERAL) {
        vm.startPrank(USER2);
        perpetuEx.depositCollateral(COLLATERAL);
        vm.stopPrank();

        // User 1 open a long position with SIZE
        vm.startPrank(USER);
        perpetuEx.createPosition(SIZE, true);
        vm.stopPrank();
        uint256 positionIdUser = perpetuEx.userPositionIdByIndex(USER, 0);
        (bool isLong, uint256 totalValue, uint256 size,,,) = perpetuEx.positions(positionIdUser);
        assert(isLong);
        assertEq(perpetuEx.collateral(USER), COLLATERAL);
        assertEq(size, SIZE);
        uint256 averageOpenPriceUser = perpetuEx.getAverageOpenPrice(positionIdUser);
        assertEq(totalValue, SIZE * averageOpenPriceUser);

        // User 2 open a short position with SIZE_2
        vm.startPrank(USER2);
        perpetuEx.createPosition(SIZE_2, false);
        vm.stopPrank();
        uint256 positionIdUser2 = perpetuEx.userPositionIdByIndex(USER2, 0);
        (bool isLong2, uint256 totalValue2, uint256 size2,,,) = perpetuEx.positions(positionIdUser2);
        assert(!isLong2);
        assertEq(perpetuEx.collateral(USER2), COLLATERAL);
        assertEq(size2, SIZE_2);
        uint256 averageOpenPriceUser2 = perpetuEx.getAverageOpenPrice(positionIdUser2);
        assertEq(totalValue2, SIZE_2 * averageOpenPriceUser2);
        console.log("Position Id of User 2", positionIdUser2);

        // User 2 closes his position
        vm.startPrank(USER2);
        perpetuEx.closePosition(positionIdUser2);
        vm.stopPrank();
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        assertEq(longOpenInterestInTokens, SIZE);
        uint256 shortOpenInterest = perpetuEx.s_shortOpenInterest();
        assertEq(shortOpenInterest, 0);
    }

    // /////////////////////
    // // Close Position
    // /////////////////////

    // TODO: test with price increasing and decreasing
    function testClosePosition() public addLiquidity(LIQUIDITY) addCollateral(COLLATERAL) {
        vm.expectRevert();
        vm.startPrank(USER);
        perpetuEx.closePosition(0);
        perpetuEx.createPosition(SIZE, true);
        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        perpetuEx.closePosition(positionId);
        vm.stopPrank();
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        uint256 shortOpenInterest = perpetuEx.s_shortOpenInterest();
        assertEq(longOpenInterestInTokens, 0);
        assertEq(shortOpenInterest, 0);

        vm.expectRevert();
        vm.startPrank(USER);
        perpetuEx.closePosition(0);
        vm.stopPrank();
    }

    ///////////////////
    // Increase Size
    ///////////////////

    function testIncreaseSize() public addLiquidity(LIQUIDITY) depositCollateralOpenLongPosition(COLLATERAL) {
        vm.startPrank(USER);
        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        perpetuEx.increaseSize(positionId, SIZE);
        vm.stopPrank();
        (, uint256 totalValue, uint256 size,,,) = perpetuEx.positions(positionId);
        // 52490,303972840000000000 * 10 **18
        // console.log(totalValue);
        uint256 expectedSize = SIZE + SIZE;
        uint256 averagePrice = perpetuEx.getAverageOpenPrice(positionId);
        uint256 expectedTotalValue = expectedSize * averagePrice;
        assertEq(size, expectedSize);
        assertEq(totalValue, expectedTotalValue);
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        assertEq(longOpenInterestInTokens, expectedSize);
    }

    ////////
    // PnL
    ////////

    // Needs it own setup
    // function testUserPnlIncreaseIfBtcPriceIncrease() public {
    //     // setup
    //     MockV3Aggregator mockV3Aggregator = new MockV3Aggregator(18, 20000e18);
    //     PerpetuEx perpetuExBtcIncrease = new PerpetuEx(address(mockV3Aggregator), IERC20(usdc));

    //     // Arrange - LP
    //     // [FAIL. Reason: ERC20: transfer amount exceeds balance]
    //     vm.startPrank(LP);
    //     IERC20(usdc).approve(address(perpetuExBtcIncrease), type(uint256).max);
    //     perpetuExBtcIncrease.deposit(LIQUIDITY, LP);
    //     vm.stopPrank();

    //     // Arrange - USER
    //     vm.startPrank(USER);
    //     perpetuExBtcIncrease.depositCollateral(COLLATERAL);
    //     perpetuExBtcIncrease.createPosition(SIZE, true);
    //     vm.stopPrank();

    //     int256 btcUsdcUpdatedPrice = 30000e18;
    //     MockV3Aggregator(priceFeed).updateAnswer(btcUsdcUpdatedPrice);
    // }

    //////////////////
    // Decrease Size
    //////////////////

    function testDecreaseSize() public longPositionOpened(LIQUIDITY, COLLATERAL, SIZE_2) {
        uint256 userBalanceBefore = IERC20(usdc).balanceOf(USER);
        console.log("userBalanceBefore", userBalanceBefore);
        vm.startPrank(USER);
        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        perpetuEx.decreaseSize(positionId, SIZE);
        vm.stopPrank();
        (, uint256 totalValue, uint256 size,,,) = perpetuEx.positions(positionId);
        uint256 expectedSize = SIZE_2 - SIZE;
        uint256 averagePrice = perpetuEx.getAverageOpenPrice(positionId);
        uint256 expectedTotalValue = expectedSize * averagePrice;
        assertEq(size, expectedSize);
        assertEq(totalValue, expectedTotalValue);
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        assertEq(longOpenInterestInTokens, expectedSize);
        uint256 balanceAfter = IERC20(usdc).balanceOf(USER);
        assertEq(balanceAfter, COLLATERAL / 2);
    }

    function testDecreaseSizeMax() public longPositionOpened(LIQUIDITY, COLLATERAL, SIZE_2) {
        vm.startPrank(USER);
        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        perpetuEx.decreaseSize(positionId, SIZE_2);
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        assertEq(longOpenInterestInTokens, 0);
        vm.stopPrank();
    }
    ///////////////////////
    // Decrease Collateral
    ///////////////////////

    function testDecreaseCollateral() public longPositionOpened(LIQUIDITY, COLLATERAL, SIZE) {
        vm.startPrank(USER);
        uint256 collateralBefore = perpetuEx.collateral(USER);
        console.log("collateralBefore", collateralBefore);
        perpetuEx.decreaseCollateral(DECREASE_COLLATERAL);
        uint256 collateralAfter = perpetuEx.collateral(USER);
        console.log("collateralAfter", collateralAfter);
        vm.stopPrank();
    }

    //forge test --match-test "testBorrowingFeesForAYear" --fork-url ${MAINNET_RPC_URL}  -vvvv
    function testBorrowingFeesForAYear() public longPositionOpened(LIQUIDITY, COLLATERAL, SIZE) {
        // fees after 1 year
        uint256 currentTimestamp = block.timestamp;
        vm.warp(currentTimestamp + SECONDS_PER_YEAR);
        uint256 borrowingFees = perpetuEx.getBorrowingFees(USER); // 2695.200999680025737280 * 1e18 in USDC
        console.log("borrowingFees", borrowingFees);
        // expected values
        uint256 borrowingRate = perpetuEx.getBorrowingRate();
        uint256 currentPrice = perpetuEx.getPriceFeed(); // BTC in USD
        uint256 positionAmount = SIZE * currentPrice;
        uint256 expectedBorrowingFees = positionAmount / borrowingRate;
        console.log("expectedBorrowingFees", expectedBorrowingFees); // 2695.201 * 1e18

        assertEq(borrowingFees / 1e16, expectedBorrowingFees / 1e16);
    }
}
