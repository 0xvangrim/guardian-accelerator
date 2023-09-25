// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployPerpetuEx} from "../../script/DeployPerpetuEx.sol";
import {PerpetuEx} from "../../src/PerpetuEx.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPerpetuEx} from "../../src/IPerpetuEx.sol";

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

    address public constant USER = address(21312312312312312312);

    // USDC contract address on mainnet
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // User mock params
    uint256 SIZE = 1;
    Position POSITION_LONG = Position(0);
    Position POSITION_SHORT = Position(1);
    uint256 COLLATERAL = 1000e6;

    function setUp() external {
        // spoof .configureMinter() call with the master minter account
        vm.prank(IUSDC(usdc).masterMinter());
        // allow this test contract to mint USDC
        IUSDC(usdc).configureMinter(address(this), type(uint256).max);
        // mint max to the test contract (or an external user)
        IUSDC(usdc).mint(USER, COLLATERAL);
        DeployPerpetuEx deployer = new DeployPerpetuEx();
        (perpetuEx, helperConfig) = deployer.run();

        vm.prank(USER);
        // IERC20(usdc).approve(address(perpetuEx), type(uint256).max);
    }

    function testBalance() public {
        uint256 balance = IERC20(usdc).balanceOf(USER);
        assertEq(balance, COLLATERAL);
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

    function testCreateOrder() public {
        vm.startPrank(USER);
        perpetuEx.depositCollateral(COLLATERAL);
        perpetuEx.createOrder(SIZE, POSITION_LONG);
        vm.stopPrank();
        // uint256 orderId = perpetuEx.userOrderIdByIndex(USER, 0);
        // (, Position position, , uint256 size, , ) = perpetuEx.orders(orderId);

        // assertEq(perpetuEx.collateral(USER), COLLATERAL);
        // // assertEq(position, POSITION_LONG);
        // assertEq(size, SIZE);
        // assertEq(perpetuEx.s_longOpenInterestInTokens(), SIZE);
    }
}
