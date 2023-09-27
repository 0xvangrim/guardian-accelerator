// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployPerpetuEx} from "../../script/DeployPerpetuEx.sol";
import {PerpetuEx} from "../../src/PerpetuEx.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPerpetuEx} from "../../src/IPerpetuEx.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

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
    address public priceFeed;

    address public constant USER = address(21312312312312312312);
    // create a liquidity provider account
    address public constant LP = address(123123123123123123123);

    // USDC contract address on mainnet
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // User mock params
    uint256 SIZE = 1;
    uint256 SIZE_2 = 2;
    uint256 COLLATERAL = 10000e6; // sufficient collateral to open a position with size 1

    // LP mock params
    uint256 LIQUIDITY = 1000000e6;

    uint256 private constant MAX_UTILIZATION_PERCENTAGE = 80; //80%
    uint256 private constant MAX_UTILIZATION_PERCENTAGE_DECIMALS = 100;

    function setUp() external {
        // spoof .configureMinter() call with the master minter account
        vm.prank(IUSDC(usdc).masterMinter());
        // allow this test contract to mint USDC
        IUSDC(usdc).configureMinter(address(this), type(uint256).max);
        // mint max to the test contract (or an external user)
        IUSDC(usdc).mint(USER, COLLATERAL);
        // mint max to the LP account
        IUSDC(usdc).mint(LP, LIQUIDITY);
        DeployPerpetuEx deployer = new DeployPerpetuEx();
        (perpetuEx, helperConfig) = deployer.run();
        (priceFeed,) = helperConfig.activeNetworkConfig();

        vm.prank(USER);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
    }

    ///////////////////////////////////////////////////
    /////////////////// MODIFIERS ////////////////////
    /////////////////////////////////////////////////

    modifier depositCollateral(uint256 amount) {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(amount);
        vm.stopPrank();
        _;
    }

    modifier addLiquidity(uint256 amount) {
        vm.startPrank(LP);
        // approve the PerpetuEx contract to spend USDC
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        perpetuEx.deposit(amount, LP);
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

    ///////////////////////////////////////////////////
    ////////////// LUIQUIDITY PROVIDERS ///////////////
    ///////////////////////////////////////////////////

    function testBalance() public {
        uint256 balance = IERC20(usdc).balanceOf(USER);
        assertEq(balance, COLLATERAL);

        uint256 LpBalance = IERC20(usdc).balanceOf(LP);
        assertEq(LpBalance, LIQUIDITY);
    }

    function testDepositCollateral() public {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(COLLATERAL);
        vm.stopPrank();
        assertEq(perpetuEx.collateral(USER), COLLATERAL);
        assertEq(IERC20(usdc).balanceOf(USER), 0);
    }

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

    function testDeposit() public {
        vm.startPrank(LP);
        // approve the PerpetuEx contract to spend USDC
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        perpetuEx.deposit(LIQUIDITY, LP);
        vm.stopPrank();
        assertEq(perpetuEx.totalAssets(), LIQUIDITY);
    }

    ///////////////////////////////////////////////////
    /////////////// INTERNAL FUNCTIONS ////////////////
    ///////////////////////////////////////////////////

    /////// set _calculateUserLeverage as public ///////
    // function testCalculateUserLeverage() public addLiquidity(LIQUIDITY) {
    //     vm.startPrank(USER);
    //     perpetuEx.depositCollateral(COLLATERAL);
    //     vm.stopPrank();
    //     assertEq(perpetuEx.collateral(USER), COLLATERAL);
    //     uint256 userCollateral = perpetuEx.collateral(USER);
    //     console.log(userCollateral);
    //     uint256 leverage = perpetuEx._calculateUserLeverage(1, USER);
    // 26218
    // console.log(leverage);
    // }

    /////// to test it set _updatedLiquidity as public ///////
    // function testUpdateLiquidity() public addLiquidity(LIQUIDITY) {
    //     uint256 updatedLiquidity = perpetuEx._updatedLiquidity();
    //     console.log(updatedLiquidity);
    //     uint256 expectedValue = LIQUIDITY * MAX_UTILIZATION_PERCENTAGE / MAX_UTILIZATION_PERCENTAGE_DECIMALS;
    //     // 800000000000
    //     assertEq(updatedLiquidity, expectedValue);
    // }

    ///////////////////////////////////////////////////
    //////////////////// TRADERS /////////////////////
    //////////////////////////////////////////////////

    function testCreateLongPosition() public addLiquidity(LIQUIDITY) depositCollateral(COLLATERAL) {
        vm.startPrank(USER);
        perpetuEx.createPosition(SIZE, true);
        vm.stopPrank();

        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        (, bool isLong, uint256 totalValue, uint256 size,,) = perpetuEx.positions(positionId);

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

    function testCreateShortPosition() public addLiquidity(LIQUIDITY) depositCollateral(COLLATERAL) {
        vm.startPrank(USER);
        perpetuEx.createPosition(SIZE, false);
        vm.stopPrank();

        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        (, bool isLong, uint256 totalValue, uint256 size,,) = perpetuEx.positions(positionId);

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

    // TODO: test with price increasing and decreasing
    function testClosePosition() public addLiquidity(LIQUIDITY) depositCollateral(COLLATERAL) {
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

    function testIncreaseSize() public addLiquidity(LIQUIDITY) depositCollateralOpenLongPosition(COLLATERAL) {
        vm.startPrank(USER);
        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        perpetuEx.increaseSize(positionId, SIZE);
        vm.stopPrank();
        (,, uint256 totalValue, uint256 size,,) = perpetuEx.positions(positionId);
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

    function testDecreaseSize() public longPositionOpened(LIQUIDITY, COLLATERAL, SIZE_2) {
        vm.startPrank(USER);
        uint256 positionId = perpetuEx.userPositionIdByIndex(USER, 0);
        perpetuEx.decreaseSize(positionId, SIZE);
        vm.stopPrank();
        (,, uint256 totalValue, uint256 size,,) = perpetuEx.positions(positionId);
        uint256 expectedSize = SIZE_2 - SIZE;
        uint256 averagePrice = perpetuEx.getAverageOpenPrice(positionId);
        uint256 expectedTotalValue = expectedSize * averagePrice;
        assertEq(size, expectedSize);
        assertEq(totalValue, expectedTotalValue);
        uint256 longOpenInterestInTokens = perpetuEx.s_longOpenInterestInTokens();
        assertEq(longOpenInterestInTokens, expectedSize);
    }
}
