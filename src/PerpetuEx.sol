// SPDX-License Identifier: MIT

pragma solidity ^0.8.19;
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {convertFromUsdToBtc} from "./Oracle.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IPerpetuEx} from "./IPerpetuEx.sol";

contract PerpetuEx is ERC4626 {
    struct Order {
        uint256 orderId;
        uint256 size;
        uint256 collateral;
        address owner;
    }

    using Oracle for uint256;
    using SafeERC20 for IERC20;

    AggregatorV3Interface public immutable s_priceFeed;

    IERC20 public immutable s_usdc;

    constructor(
        address priceFeed,
        IERC20 _usdc
    ) ERC4626(_usdc) ERC20("PerpetuEx", "PXT") {
        s_priceFeed = AggregatorV3Interface(priceFeed);
        s_usdc = IERC20(_usdc);
    }

    mapping(address => uint256) collateral;

    //  ====================================
    //  ==== External/Public Functions =====
    //  ====================================

    function deposit(uint256 _amount) external {}

    function withdraw(uint256 _amount) external {}

    function depositCollateral(uint256 _amount) external {
        if (_amount < 0)
            revert PerpetuEx__InvalidAmount(
                usdc.safeTransferFrom(msg.sender, address(this), _amount)
            );
    }

    function withdrawCollateral(uint256 _amount) external {}

    function createOrder(uint256 _size, uint256 _collateral) external {
        if (_size < 0) revert PerpetuEx__InvalidSize();
        if (_collateral < 0) revert PerpetuEx__InvalidCollateral();
        //check that collateral is enough
    }

    function updateSize(
        uint256 _orderId,
        uint256 _size,
        uint256 collateral
    ) external {
        if (_size < 0) revert PerpetuEx__InvalidSize();
        //check that collateral is enough
    }

    function updateCollateral(uint256 _orderId, uint256 _collateral) external {
        if (_collateral < 0) revert PerpetuEx__InvalidCollateral();
        //check that collateral is enough
        usdc.safeTransferFrom(msg.sender, address(this), _collateral);
    }

    function updateOrder() external {}

    /// ====================================
    /// ======= Internal Functions =========
    /// ====================================

    // =========================
    // ==== View Functions =====
    // =========================

    function getPriceFeed() view returns (AggregatorV3Interface) {
        return s_priceFeed;
    }

    function getConversionRate(uint256 _amount) view returns (uint256) {
        return convertFromUsdToBtc(_amount);
    }
}
