// SPDX-License Identifier: MIT

pragma solidity ^0.8.19;
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Oracle} from "./Oracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract PerpetuEx is ERC4626 {
    struct Order {
        uint256 orderId;
        uint256 size;
        uint256 collateral;
        address owner;
    }

    using Oracle for uint256;
    using SafeERC20 for IERC20;
    using Math for uint256;

    AggregatorV3Interface public immutable s_priceFeed;
    IERC20 public immutable s_usdc;

    // 20% of the liquidity reserved for safety reasons
    uint256 private constant MAX_UTILIZATION_PERCENTAGE = 80; //80%
    uint256 private constant MAX_UTILIZATION_PERCENTAGE_DECIMALS = 100;
    uint256 public totalPnl = 100 * 10 ** 6; // hardcoded for now

    constructor(address priceFeed, IERC20 _usdc) ERC4626(_usdc) ERC20("PerpetuEx", "PXT") {
        s_priceFeed = AggregatorV3Interface(priceFeed);
        s_usdc = IERC20(_usdc);
    }

    //  ====================================
    //  ==== External/Public Functions =====
    //  ====================================

    function deposit(uint256 _amount) external {}

    function withdraw(uint256 _amount) external {}

    function createOrder(uint256 _size, uint256 _collateral) external {
        require(_size > 0, "Size must be greater than 0");
        require(_collateral > 0, "Collateral must be greater than 0");
        //check that collateral is enough
    }

    function updateSize(uint256 _orderId, uint256 _size, uint256 collateral) external {
        require(_size > 0, "Size must be greater than 0");
        //check that collateral is enough
    }

    function updateCollateral(uint256 _orderId, uint256 _collateral) external {
        require(_collateral > 0, "Collateral must be greater than 0");
        //check that collateral is enough
    }

    function updateOrder() external {}

    /// ====================================
    /// ======= Internal Functions =========
    /// ====================================

    // =========================
    // ==== View Functions =====
    // =========================

    function getPriceFeed() external view returns (AggregatorV3Interface) {
        return s_priceFeed;
    }

    function maxWithdraw(address owner) public view override returns (uint256 maxWithdrawAllowed) {
        uint256 ownerBalance = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 ownerAssets = super.convertToAssets(ownerBalance);

        uint256 liquidityReserveRestriction =
            totalAssets().mulDiv(MAX_UTILIZATION_PERCENTAGE, MAX_UTILIZATION_PERCENTAGE_DECIMALS);

        uint256 updatedLiquidity = liquidityReserveRestriction - totalPnl;

        if (ownerAssets >= liquidityReserveRestriction) {
            return maxWithdrawAllowed = ownerAssets - updatedLiquidity;
        }

        if (ownerAssets < updatedLiquidity) {
            return maxWithdrawAllowed = ownerAssets;
        }
    }

    function totalAssets() public view override returns (uint256) {
        //assuming 1usdc = $1
        return s_usdc.balanceOf(address(this)) - totalPnl;
    }
}
