// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployPerpetuEx} from "../../script/DeployPerpetuEx.sol";
import {PerpetuEx} from "../../src/PerpetuEx.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPerpetuEx} from "../../src/IPerpetuEx.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    address public constant USER = address(21312312312312312312);
    // create a liquidity provider account
    address public constant LP = address(123123123123123123123);

    // USDC contract address on mainnet
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // User mock params
    uint256 SIZE = 1;
    uint256 COLLATERAL = 10000e6; // sufficient collateral to open a position with size 1

    // LP mock params
    uint256 LIQUIDITY = 1000000e6;

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
        vm.prank(USER);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
        vm.prank(LP);
        IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
    }
    // create a modifier to add liquidity

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

    //@dev this mimics the share calculation behavior in ERC4626
    function _shareCalculation(uint256 assets) public returns (uint256 withdrawShares) {
        withdrawShares = Math.mulDiv(assets, perpetuEx.totalSupply() + 10 ** 0, perpetuEx.totalAssets() + 1, 0);
    }

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
        console.log(allAssets, "allAssets");
        uint256 maxLiquidity =
            allAssets * perpetuEx.getMaxUtilizationPercentage() / perpetuEx.getMaxUtilizationPercentageDecimals();
        console.log(maxLiquidity, "maxLiquidity");
        console.log(IERC20(perpetuEx).balanceOf(LP), "IERC20(perpetuEx).balanceOf(LP)");
        uint256 maxLiquidityToWithdraw = perpetuEx.getTotalLiquidityDeposited()
            * perpetuEx.getMaxUtilizationPercentage() / perpetuEx.getMaxUtilizationPercentageDecimals();
        uint256 withdrawShares = _shareCalculation(maxLiquidityToWithdraw);
        console.log(maxLiquidityToWithdraw, "maxLiquidityToWithdraw");
        console.log(perpetuEx.getTotalLiquidityDeposited(), "totalLiquidity() Deposited before");
        vm.startPrank(LP);
        perpetuEx.withdraw(maxLiquidityToWithdraw, LP, LP);
        console.log(perpetuEx.getTotalLiquidityDeposited(), "totalLiquidity() Deposited after");
        console.log(perpetuEx.totalAssets(), "totalAssets() after withdraw");
        vm.stopPrank();
        assertEq(perpetuEx.totalAssets(), perpetuEx.getTotalLiquidityDeposited());
        assertEq(perpetuEx.totalSupply(), DEAD_SHARES + allAssets - withdrawShares);
        assertEq(IERC20(usdc).balanceOf(LP), maxLiquidityToWithdraw);
        // assertEq(IERC20(perpetuEx).balanceOf(LP), LIQUIDITY - maxLiquidityToWithdraw);
    }

    //@func redeem
    // function testRedeem() public addLiquidity(LIQUIDITY) {
    //     uint256 allAssets = perpetuEx.totalSupply();
    //     uint256 maxLiquidity =
    //         allAssets * perpetuEx.getMaxUtilizationPercentage() / perpetuEx.getMaxUtilizationPercentageDecimals();
    //     vm.startPrank(LP);
    //     perpetuEx.redeem(maxLiquidity, LP, LP);
    //     vm.stopPrank();
    //     assertEq(perpetuEx.totalAssets(), allAssets - maxLiquidity);
    //     assertEq(perpetuEx.totalSupply(), allAssets - maxLiquidity);
    //     assertEq(IERC20(usdc).balanceOf(LP), maxLiquidity);
    //     assertEq(IERC20(perpetuEx).balanceOf(LP), allAssets - maxLiquidity);
    // }

    //@func mint
    // function testMint() public {
    //     vm.startPrank(LP);
    //     perpetuEx.mint(1000, LP);
    //     vm.stopPrank();
    //     assertEq(perpetuEx.totalAssets(), 1000);
    //     assertEq(perpetuEx.totalSupply(), 1000);
    //     assertEq(IERC20(perpetuEx).balanceOf(LP), 1000);
    // }

    // function testCalculateUserLeverage() public {
    //     vm.startPrank(USER);
    //     perpetuEx.depositCollateral(COLLATERAL);
    //     vm.stopPrank();
    //     assertEq(perpetuEx.collateral(USER), COLLATERAL);
    //     uint256 userCollateral = perpetuEx.collateral(USER);
    //     console.log(userCollateral);
    //     uint256 leverage = perpetuEx._calculateUserLeverage(1, USER);
    //     console.log(leverage);
    // }

    // function testCreatePosition() public addLiquidity(LIQUIDITY) {
    //     vm.startPrank(USER);
    //     perpetuEx.depositCollateral(COLLATERAL);
    //     perpetuEx.createPosition(SIZE, true);
    //     vm.stopPrank();
    // }
}
