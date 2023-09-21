// SPDX-License Identifier: MIT

pragma solidity ^0.8.19;
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Oracle} from "./Oracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PerpetuEx {
    struct Order {
        uint256 orderId;
        uint256 size;
        uint256 collateral;
        address owner;
    }

    using Oracle for uint256;
    AggregatorV3Interface public s_priceFeed;

    constructor(address priceFeed) {
        s_priceFeed = AggregatorV3Interface(priceFeed);
    }

    //  ====================================
    //  ==== External/Public Functions =====
    //  ====================================

    function deposit(uint256 _amount) external payable {}

    function withdraw(uint256 _amount) external {}

    function createOrder(uint256 _size, uint256 _collateral) external {
        require(_size > 0, "Size must be greater than 0");
        require(_collateral > 0, "Collateral must be greater than 0");
        //check that collateral is enough
    }

    function updateSize(
        uint256 _orderId,
        uint256 _size,
        uint256 collateral
    ) external {
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
}
