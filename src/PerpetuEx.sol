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
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

contract PerpetuEx is ERC4626, IPerpetuEx {
    struct Order {
        uint256 orderId;
        Position position;
        uint256 totalValue; // Accumulated USD value committed to the position
        uint256 size;
        uint256 collateral;
        address owner;
    }

    using Oracle for uint256;
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    AggregatorV3Interface public immutable s_priceFeed;

    IERC20 public immutable s_usdc;

    // 20% of the liquidity reserved for safety reasons
    uint256 private constant MAX_UTILIZATION_PERCENTAGE = 80; //80%
    uint256 private constant MAX_UTILIZATION_PERCENTAGE_DECIMALS = 100;
    uint256 private constant MAX_LEVERAGE = 20;
    uint256 private s_nonce;
    uint256 public s_totalCollateral;
    int256 public s_totalPnl;
    uint256 public s_shortOpenInterest;
    uint256 public s_longOpenInterestInTokens;

    constructor(address priceFeed, IERC20 _usdc) ERC4626(_usdc) ERC20("PerpetuEx", "PXT") {
        s_priceFeed = AggregatorV3Interface(priceFeed);
        s_usdc = IERC20(_usdc);
        // TODO: Mint dead shares
    }

    mapping(address => uint256) public collateral; //User to collateral mapping
    mapping(uint256 => Order) public orders; // orderId => Order
    mapping(address => EnumerableSet.UintSet) private userToOrderIds; // user => orderIds
    mapping(address => int256) public userShortPnl; // user => short pnl
    mapping(address => int256) public userLongPnl; // user => long pnl

    //  ====================================
    //  ==== External/Public Functions =====
    //  ====================================

    function depositCollateral(uint256 _amount) external {
        if (_amount < 0) revert PerpetuEx__InvalidAmount();
        collateral[msg.sender] += _amount;
        s_usdc.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function withdrawCollateral() external {
        if (collateral[msg.sender] == 0) {
            revert PerpetuEx__InsufficientCollateral();
        }
        if (userToOrderIds[msg.sender].length() > 0) {
            revert PerpetuEx__OpenPositionExists();
        }
        collateral[msg.sender] = 0;
        s_usdc.safeTransfer(msg.sender, collateral[msg.sender]);
    }

    function createOrder(uint256 _size, Position _position) external {
        if (_size == 0 || _calculateUserLeverage(_size, msg.sender) > MAX_LEVERAGE) {
            revert PerpetuEx__InvalidSize();
        }
        if (_position != Position.Long || _position != Position.Short) {
            revert PerpetuEx__NoPositionChosen();
        }
        uint256 currentOrderId = ++s_nonce;
        uint256 currentPrice = getPriceFeed();
        Order memory newOrder = Order({
            orderId: currentOrderId,
            size: _size,
            collateral: collateral[msg.sender],
            totalValue: _size * currentPrice,
            owner: msg.sender,
            position: _position
        });
        // check that s_shortOpenInterest + s_longOpenInterestInTokens < 80% of total assets
        uint256 updatedLiquidity = _updatedLiquidity();
        if (_position == Position.Long) {
            if (((s_longOpenInterestInTokens + _size) * currentPrice) + s_shortOpenInterest >= updatedLiquidity) {
                revert PerpetuEx__InsufficientLiquidity();
            }
        } else {
            if (
                s_shortOpenInterest + (_size * currentPrice) + (s_longOpenInterestInTokens * currentPrice)
                    > updatedLiquidity
            ) {
                revert PerpetuEx__InsufficientLiquidity();
            }
        }
        // Update s_longOpenInterestInTokens if long or s_shortOpenInterest if short
        if (_position == Position.Long) {
            s_longOpenInterestInTokens += _size;
        } else {
            s_shortOpenInterest += _size * currentPrice;
        }
        orders[currentOrderId] = newOrder;
        userToOrderIds[msg.sender].add(currentOrderId);
    }

    function closeOrder(uint256 _orderId) external {
        Order storage order = orders[_orderId];
        if (order.owner != msg.sender) revert PerpetuEx__NotOwner();
        // calculate pnl for user and add to total pnl
        int256 pnl = _calculateUserPnl(_orderId, order.position);
        // update trader's collateral, profits or losses are now realized, trader can withdraw if he wants to
        if (pnl >= 0) {
            collateral[msg.sender] += uint256(pnl);
        } else {
            uint256 unsignedPnl = SignedMath.abs(pnl);
            collateral[msg.sender] -= unsignedPnl;
        }
        // Update s_longOpenInterestInTokens if long or s_shortOpenInterest if short
        if (order.position == Position.Long) {
            s_longOpenInterestInTokens -= order.size;
        } else {
            uint256 averagePrice = getAverageOpenPrice(_orderId);
            s_shortOpenInterest -= order.size * averagePrice;
        }
        s_totalPnl += _calculateUserPnl(_orderId, order.position);
        userToOrderIds[msg.sender].remove(_orderId);

        delete orders[_orderId];
    }

    function increaseSize(uint256 _orderId, uint256 _size) external {
        Order storage order = orders[_orderId];
        uint256 currentPrice = getPriceFeed();
        if (order.owner != msg.sender) revert PerpetuEx__NotOwner();
        if (_size == 0 || _calculateUserLeverage(_size, msg.sender) > MAX_LEVERAGE) {
            revert PerpetuEx__InvalidSize();
        }
        // Calculate the total USD value of the new position being added
        uint256 addedValue = _size * currentPrice;
        // Update s_longOpenInterestInTokens if long or s_shortOpenInterest if short
        if (order.position == Position.Long) {
            s_longOpenInterestInTokens += _size;
        } else {
            s_shortOpenInterest += _size * currentPrice;
        }
        // Update the total value and size of the order
        order.totalValue += addedValue;
        order.size += _size;
    }

    function increaseCollateral(uint256 _orderId, uint256 _collateral) external {
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
    function _updatedLiquidity() internal view returns (uint256 updatedLiquidity) {
        uint256 liquidityReserveRestriction =
            totalAssets().mulDiv(MAX_UTILIZATION_PERCENTAGE, MAX_UTILIZATION_PERCENTAGE_DECIMALS);
        uint256 totalPnl = SignedMath.abs(s_totalPnl);
        if (s_totalPnl >= 0) {
            updatedLiquidity = liquidityReserveRestriction - totalPnl;
        }
        if (s_totalPnl < 0) {
            updatedLiquidity = liquidityReserveRestriction + totalPnl;
        }
    }

    // =========================
    // ==== View/Pure Functions =====
    // =========================

    function getPriceFeed() public view returns (uint256) {
        return Oracle.getBtcInUsdPrice(s_priceFeed);
    }

    function _getConversionRate(uint256 _amount) internal view returns (uint256) {
        return Oracle.convertPriceFromUsdToBtc(_amount, s_priceFeed);
    }

    function getAverageOpenPrice(uint256 _orderId) public view returns (uint256) {
        Order memory order = orders[_orderId];
        if (orders[_orderId].orderId == 0) revert PerpetuEx__InvalidOrderId();
        return order.totalValue / order.size;
    }

    function _calculateUserLeverage(uint256 _size, address _user) internal view returns (uint256 userLeverage) {
        uint256 priceFeed = getPriceFeed();
        if (userToOrderIds[_user].length() > 0) {
            int256 userPnl =
                _calculateUserPnl(userToOrderIds[_user].at(0), orders[userToOrderIds[_user].at(0)].position);
            if (userPnl >= 0) {
                userLeverage = _size.mulDiv(priceFeed, collateral[msg.sender] + uint256(userPnl));
            } else {
                uint256 unsignedPnl = SignedMath.abs(userPnl);
                userLeverage = _size.mulDiv(priceFeed, collateral[msg.sender] - unsignedPnl);
            }
        } else {
            userLeverage = _size.mulDiv(priceFeed, collateral[msg.sender]);
        }
    }

    function _calculateUserPnl(uint256 _orderId, Position _position) internal view returns (int256 pnl) {
        uint256 currentPrice = getPriceFeed();
        uint256 averagePrice = getAverageOpenPrice(_orderId);
        Order storage order = orders[_orderId];

        if (_position == Position.Long) {
            pnl = int256(currentPrice - averagePrice) * int256(order.size);
        } else if (_position == Position.Short) {
            pnl = int256(averagePrice - currentPrice) * int256(order.size);
        } else {
            revert PerpetuEx__NoPositionChosen();
        }
    }

    function maxWithdraw(address owner) public view override returns (uint256 maxWithdrawAllowed) {
        uint256 ownerAssets = super._convertToAssets(balanceOf(owner), Math.Rounding.Floor);

        uint256 updatedLiquidity = _updatedLiquidity();

        if (ownerAssets >= updatedLiquidity) {
            return maxWithdrawAllowed = ownerAssets - updatedLiquidity;
        }

        if (ownerAssets < updatedLiquidity) {
            return maxWithdrawAllowed = ownerAssets;
        }
    }

    function maxRedeem(address owner) public view override returns (uint256 maxRedeemAllowed) {
        uint256 ownerAssets = super._convertToAssets(balanceOf(owner), Math.Rounding.Floor);

        uint256 updatedLiquidity = _updatedLiquidity();

        if (ownerAssets >= updatedLiquidity) {
            uint256 maxAssetsAllowed = ownerAssets - updatedLiquidity;
            return maxRedeemAllowed = super._convertToShares(maxAssetsAllowed, Math.Rounding.Floor);
        }

        if (ownerAssets < updatedLiquidity) {
            return maxRedeemAllowed = super._convertToShares(ownerAssets, Math.Rounding.Floor);
        }
    }

    function totalAssets() public view override returns (uint256) {
        //assuming 1usdc = $1
        if (s_totalPnl >= 0) {
            uint256 totalPnl = uint256(s_totalPnl);
            return s_usdc.balanceOf(address(this)) - totalPnl - s_totalCollateral;
        }
        if (s_totalPnl < 0) {
            uint256 totalPnl = SignedMath.abs(s_totalPnl);
            return s_usdc.balanceOf(address(this)) + totalPnl - s_totalCollateral;
        }
    }
}
