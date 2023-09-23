// SPDX-License Identifier: MIT

pragma solidity ^0.8.19;
// import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Oracle} from "./Oracle.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IPerpetuEx} from "./IPerpetuEx.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract PerpetuEx is ERC4626, IPerpetuEx {
    struct Order {
        uint256 orderId;
        Position position;
        uint256 openPrice;
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
    uint256 private constant MAX_LEVERAGE = 20;
    uint256 private s_nonce;
    uint256 public s_totalCollateral;
    uint256 public s_totalPnl = 100 * 10 ** 6; // hardcoded for now

    constructor(
        address priceFeed,
        IERC20 _usdc
    ) ERC4626(_usdc) ERC20("PerpetuEx", "PXT") {
        s_priceFeed = AggregatorV3Interface(priceFeed);
        s_usdc = IERC20(_usdc);
        // TODO: Mint dead shares
    }

    mapping(address => uint256) public collateral; //User to collateral mapping
    mapping(uint256 => Order) public orders; // All orders by orderId
    mapping(address => uint256[]) public userToOrderIds; // User's orderIds
    mapping(address => mapping(uint256 => uint256)) public userOrderIdToIndex; // user address => orderId => index in userToOrderIds

    //  ====================================
    //  ==== External/Public Functions =====
    //  ====================================

    function depositCollateral(uint256 _amount) external {
        if (_amount < 0) revert PerpetuEx__InvalidAmount();
        collateral[msg.sender] += _amount;
        s_usdc.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function withdrawCollateral() external {
        if (collateral[msg.sender] == 0)
            revert PerpetuEx__InsufficientCollateral();
        collateral[msg.sender] = 0;
        s_usdc.safeTransfer(msg.sender, collateral[msg.sender]);
    }

    function createOrder(uint256 _size, Position _position) external {
        if (_size == 0 || _calculateUserLeverage(_size) > MAX_LEVERAGE)
            revert PerpetuEx__InvalidSize();
        if (_position != Position.Long || _position != Position.Short)
            revert PerpetuEx__NoPositionChosen();
        uint256 currentOrderId = ++s_nonce;

        Order memory newOrder = Order({
            orderId: currentOrderId,
            openPrice: _getConversionRate(_size),
            size: _size,
            collateral: collateral[msg.sender],
            owner: msg.sender,
            position: _position
        });

        orders[currentOrderId] = newOrder;
        userToOrderIds[msg.sender].push(currentOrderId);
        userOrderIdToIndex[msg.sender][currentOrderId] =
            userToOrderIds[msg.sender].length -
            1;
    }

    function closeOrder(uint256 _orderId) external {
        Order storage order = orders[_orderId];
        if (order.owner != msg.sender) revert PerpetuEx__NotOwner();

        // Remove the orderId from userToOrderIds array using a swap-and-pop method
        uint256 indexToRemove = userOrderIdToIndex[msg.sender][_orderId];
        uint256 lastOrderId = userToOrderIds[msg.sender][
            userToOrderIds[msg.sender].length - 1
        ];

        userToOrderIds[msg.sender][indexToRemove] = lastOrderId;
        userOrderIdToIndex[msg.sender][lastOrderId] = indexToRemove;
        userToOrderIds[msg.sender].pop();

        delete userOrderIdToIndex[msg.sender][_orderId];
        delete orders[_orderId];
    }

    function updateSize(uint256 _orderId, uint256 _size) external {
        Order storage order = orders[_orderId];
        if (_size == 0 || _calculateUserLeverage(_size) > MAX_LEVERAGE)
            revert PerpetuEx__InvalidSize();
        if (order.owner != msg.sender) revert PerpetuEx__NotOwner();
        order.size = _size;
    }

    function updateCollateral(uint256 _orderId, uint256 _collateral) external {
        Order storage order = orders[_orderId];
        if (_collateral == 0) revert PerpetuEx__InvalidCollateral();
        if (order.owner != msg.sender) revert PerpetuEx__NotOwner();
        order.collateral += _collateral;
        s_usdc.safeTransferFrom(msg.sender, address(this), _collateral);
    }

    /// ====================================
    /// ======= Internal Functions =========
    /// ====================================
    /**
     * @dev Compute the liquidity reserve restriction and substract the total pnl of traders from it
     */
    function _updatedLiquidity()
        internal
        view
        returns (uint256 updatedLiquidity)
    {
        uint256 liquidityReserveRestriction = totalAssets().mulDiv(
            MAX_UTILIZATION_PERCENTAGE,
            MAX_UTILIZATION_PERCENTAGE_DECIMALS
        );

        updatedLiquidity = liquidityReserveRestriction - s_totalPnl;
    }

    // =========================
    // ==== View/Pure Functions =====
    // =========================

    function getPriceFeed() public view returns (uint256) {
        return Oracle.getBtcInUsdPrice(s_priceFeed);
    }

    function _getConversionRate(
        uint256 _amount
    ) internal view returns (uint256) {
        return Oracle.convertPriceFromUsdToBtc(_amount, s_priceFeed);
    }

    function _calculateUserLeverage(
        uint256 _size
    ) internal view returns (uint256 userLeverage) {
        uint256 priceFeed = getPriceFeed();
        userLeverage = _size.mulDiv(priceFeed, collateral[msg.sender]);
    }

    function maxWithdraw(
        address owner
    ) public view override returns (uint256 maxWithdrawAllowed) {
        uint256 ownerAssets = super._convertToAssets(
            balanceOf(owner),
            Math.Rounding.Floor
        );

        uint256 updatedLiquidity = _updatedLiquidity();

        if (ownerAssets >= updatedLiquidity) {
            return maxWithdrawAllowed = ownerAssets - updatedLiquidity;
        }

        if (ownerAssets < updatedLiquidity) {
            return maxWithdrawAllowed = ownerAssets;
        }
    }

    function maxRedeem(
        address owner
    ) public view override returns (uint256 maxRedeemAllowed) {
        uint256 ownerAssets = super._convertToAssets(
            balanceOf(owner),
            Math.Rounding.Floor
        );

        uint256 updatedLiquidity = _updatedLiquidity();

        if (ownerAssets >= updatedLiquidity) {
            uint256 maxAssetsAllowed = ownerAssets - updatedLiquidity;
            return
                maxRedeemAllowed = _convertToShares(
                    maxAssetsAllowed,
                    Math.Rounding.Floor
                );
        }

        if (ownerAssets < updatedLiquidity) {
            return
                maxRedeemAllowed = _convertToShares(
                    ownerAssets,
                    Math.Rounding.Floor
                );
        }
    }

    function totalAssets() public view override returns (uint256) {
        //assuming 1usdc = $1
        return s_usdc.balanceOf(address(this)) - s_totalPnl - s_totalCollateral;
    }
}
