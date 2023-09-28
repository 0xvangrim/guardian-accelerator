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
    address public priceFeed;
    DeployPerpetuEx public deployer;
    address public constant USER = address(21312312312312312312);
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

    // Dead shares
    uint256 DEAD_SHARES = 1000;

    function setUp() external {
        // spoof .configureMinter() call with the master minter account
        vm.prank(IUSDC(usdc).masterMinter());
        // allow this test contract to mint USDC
        IUSDC(usdc).configureMinter(address(this), type(uint256).max);
        // mint max to the test contract (or an external user)
        IUSDC(usdc).mint(USER, COLLATERAL);
        // mint max to the LP account
        IUSDC(usdc).mint(LP, LIQUIDITY);
        deployer = new DeployPerpetuEx();
        (perpetuEx, helperConfig) = deployer.run();
        (priceFeed,) = helperConfig.activeNetworkConfig();
        vm.prank(USER);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        vm.prank(LP);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
    }

    ///////////////////////////////////////////////////
    /////////////////// MODIFIERS ////////////////////
    /////////////////////////////////////////////////

    modifier addCollateral(uint256 amount) {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(amount);
        vm.stopPrank();
        _;
    }

    modifier addLiquidity(uint256 amount) {
        vm.startPrank(LP);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        perpetuEx.deposit(amount, LP);
        vm.stopPrank();
        _;
    }

    //@dev this mimics the share calculation behavior in ERC4626
    function shareCalculation(uint256 assets) public returns (uint256 withdrawShares) {
        withdrawShares =
            Math.mulDiv(assets, perpetuEx.totalSupply() + 10 ** 0, perpetuEx.totalAssets() + 1, Math.Rounding.Floor);
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

    function testSharesOnDeployment() public {
        assertEq(perpetuEx.totalSupply(), DEAD_SHARES);
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

    /////////////////////
    /// Create Position
    /////////////////////

    function testCreateLongPosition() public addLiquidity(LIQUIDITY) addCollateral(COLLATERAL) {
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

    function testCreateShortPosition() public addLiquidity(LIQUIDITY) addCollateral(COLLATERAL) {
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
}
