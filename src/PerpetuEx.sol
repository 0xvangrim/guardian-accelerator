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
import {console} from "forge-std/Console.sol";

contract PerpetuEx is ERC4626, IPerpetuEx {
    struct Position {
        bool isLong;
        uint256 totalValue; // Accumulated USD value committed to the position
        uint256 size;
        uint256 collateral;
        address owner;
    }

    using Oracle for uint256;
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    AggregatorV3Interface public immutable i_priceFeed;

    IERC20 public immutable i_usdc;

    // 20% of the liquidity reserved for safety reasons
    uint256 private constant MAX_UTILIZATION_PERCENTAGE = 80; //80%
    uint256 private constant MAX_UTILIZATION_PERCENTAGE_DECIMALS = 100;
    uint256 private constant MAX_LEVERAGE = 20;
    uint16 private constant DEAD_SHARES = 1000;
    // price feed decimals
    uint256 private constant PRICE_FEED_DECIMALS = 10 ** 18;
    uint256 private constant USDC_DECIMALS = 10 ** 6;

    uint256 private s_nonce;
    uint256 public s_totalLiquidityDeposited;
    int256 public s_totalPnl;
    uint256 public s_shortOpenInterest;
    uint256 public s_longOpenInterestInTokens;

    constructor(address priceFeed, IERC20 _usdc) ERC4626(_usdc) ERC20("PerpetuEx", "PXT") {
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_usdc = IERC20(_usdc);

        //Avoiding the inflation attack by sending shares to the contract
        _mint(address(this), DEAD_SHARES);
    }

    mapping(address => uint256) public collateral; //User to collateral mapping
    mapping(uint256 => Position) public positions; // positionId => position
    mapping(address => EnumerableSet.UintSet) internal userToPositionIds; // user => positionIds
    mapping(address => int256) public userShortPnl; // user => short pnl
    mapping(address => int256) public userLongPnl; // user => long pnl

    //  ====================================
    //  ==== External/Public Functions =====
    //  ====================================

    function depositCollateral(uint256 _amount) external {
        if (_amount < 0) revert PerpetuEx__InvalidAmount();
        collateral[msg.sender] += _amount;
        i_usdc.safeTransferFrom(msg.sender, address(this), _amount);
    }

    function withdrawCollateral() external {
        if (collateral[msg.sender] == 0) {
            revert PerpetuEx__InsufficientCollateral();
        }
        if (userToPositionIds[msg.sender].length() > 0) {
            revert PerpetuEx__OpenPositionExists();
        }
        uint256 withdrawalAmount = collateral[msg.sender];
        collateral[msg.sender] = 0;
        i_usdc.safeTransfer(msg.sender, withdrawalAmount);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        uint256 newTotalLiquidity = s_totalLiquidityDeposited + assets;
        shares = super.deposit(assets, receiver);
        s_totalLiquidityDeposited = newTotalLiquidity;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        uint256 newTotalLiquidity = s_totalLiquidityDeposited - assets;
        shares = super.withdraw(assets, receiver, owner);
        s_totalLiquidityDeposited = newTotalLiquidity;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        s_totalLiquidityDeposited += assets;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = super.redeem(shares, receiver, owner);
        s_totalLiquidityDeposited -= assets;
    }

    function createPosition(uint256 _size, bool _isLong) external {
        if (_size == 0 || _calculateUserLeverage(_size, msg.sender) > MAX_LEVERAGE) {
            revert PerpetuEx__InvalidSize();
        }
        //TODO: Add support for more orderes from the same user. For now we block it.
        if (userToPositionIds[msg.sender].length() > 0) {
            revert PerpetuEx__OpenPositionExists();
        }
        //TODO: compute positionId keccak256(abi.encode(owner + nonce)) to avoid position id collision
        ++s_nonce;
        uint256 currentPrice = getPriceFeed();
        Position memory newPosition = Position({
            size: _size,
            collateral: collateral[msg.sender],
            totalValue: _size * currentPrice,
            owner: msg.sender,
            isLong: _isLong
        });
        // check that s_shortOpenInterest + s_longOpenInterestInTokens < 80% of total assets
        if (_totalOpenInterest(_isLong, _size, currentPrice) >= _updatedLiquidity()) {
            revert PerpetuEx__InsufficientLiquidity();
        }
        // Update the actual open interests
        _updateOpenInterests(_isLong, _size, currentPrice, PositionAction.Open);
        positions[s_nonce] = newPosition;
        userToPositionIds[msg.sender].add(s_nonce);
    }

    function closePosition(uint256 _positionId) external {
        Position storage position = positions[_positionId];
        if (_positionId == 0) revert PerpetuEx__InvalidPositionId();
        if (position.owner != msg.sender) revert PerpetuEx__NotOwner();
        // calculate pnl for user and add to total pnl
        int256 pnl = _calculateUserPnl(_positionId, position.isLong);
        // update trader's collateral, profits or losses are now realized, trader can withdraw if he wants to
        if (pnl >= 0) {
            collateral[msg.sender] += uint256(pnl);
        }
        if (pnl < 0) {
            uint256 unsignedPnl = SignedMath.abs(pnl);
            collateral[msg.sender] -= unsignedPnl;
        }
        // Update s_longOpenInterestInTokens if long or s_shortOpenInterest if short
        _updateOpenInterests(position.isLong, position.size, getAverageOpenPrice(_positionId), PositionAction.Close);
        s_totalPnl += _calculateUserPnl(_positionId, position.isLong);
        userToPositionIds[msg.sender].remove(_positionId);

        delete positions[_positionId];
    }

    function increaseSize(uint256 _positionId, uint256 _size) external {
        Position storage position = positions[_positionId];
        uint256 currentPrice = getPriceFeed();
        if (position.owner != msg.sender) revert PerpetuEx__NotOwner();
        if (_size == 0 || _calculateUserLeverage(_size, msg.sender) > MAX_LEVERAGE) {
            revert PerpetuEx__InvalidSize();
        }
        if (_totalOpenInterest(position.isLong, _size, currentPrice) >= _updatedLiquidity()) {
            revert PerpetuEx__InsufficientLiquidity();
        }
        // Calculate the total USD value of the new position being added
        uint256 addedValue = _size * currentPrice;
        // Update s_longOpenInterestInTokens if long or s_shortOpenInterest if short
        _updateOpenInterests(position.isLong, _size, currentPrice, PositionAction.Open);
        // Update the total value and size of the order
        position.totalValue += addedValue;
        position.size += _size;
    }

    function increaseCollateral(uint256 _positionId, uint256 _collateral) external {
        Position storage position = positions[_positionId];
        if (_collateral == 0) revert PerpetuEx__InvalidCollateral();
        if (position.owner != msg.sender) revert PerpetuEx__NotOwner();
        position.collateral += _collateral;
        i_usdc.safeTransferFrom(msg.sender, address(this), _collateral);
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

    function _totalOpenInterest(bool _isLong, uint256 _size, uint256 _currentPrice)
        internal
        view
        returns (uint256 totalOpenInterestValue)
    {
        // Calculate new open interests
        uint256 newLongOpenInterestInTokens = _isLong ? s_longOpenInterestInTokens + _size : s_longOpenInterestInTokens;

        uint256 newShortOpenInterest = !_isLong ? s_shortOpenInterest + (_size * _currentPrice) : s_shortOpenInterest;

        // Calculate the total open interest value
        totalOpenInterestValue = (newLongOpenInterestInTokens * _currentPrice) + newShortOpenInterest;
    }

    function _updateOpenInterests(bool _isLong, uint256 _size, uint256 _price, PositionAction positionAction)
        internal
    {
        if (_isLong) {
            if (positionAction == PositionAction.Open) {
                s_longOpenInterestInTokens += _size;
            } else if (positionAction == PositionAction.Close) {
                s_longOpenInterestInTokens -= _size;
            }
        } else if (!_isLong) {
            uint256 valueChange = _size * _price;
            if (positionAction == PositionAction.Open) {
                s_shortOpenInterest += valueChange;
            } else if (positionAction == PositionAction.Close) {
                s_shortOpenInterest -= valueChange;
            }
        } else {
            revert PerpetuEx__NoPositionChosen();
        }
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        if (totalSupply() == 0) return assets;
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    // =========================
    // ==== View/Pure Functions =====
    // =========================

    function userPositionIdByIndex(address user, uint256 index) public view returns (uint256) {
        return userToPositionIds[user].at(index);
    }

    function getPriceFeed() public view returns (uint256) {
        return Oracle.getBtcInUsdPrice(i_priceFeed);
    }

    function _getConversionRate(uint256 _amount) internal view returns (uint256) {
        return Oracle.convertPriceFromUsdToBtc(_amount, i_priceFeed);
    }

    function getAverageOpenPrice(uint256 _positionId) public view returns (uint256) {
        Position memory position = positions[_positionId];
        if (_positionId == 0) revert PerpetuEx__InvalidPositionId();
        return position.totalValue / position.size;
    }

    function getTotalPnl() public view returns (int256) {
        return s_totalPnl;
    }

    function getTotalLiquidityDeposited() public view returns (uint256) {
        return s_totalLiquidityDeposited;
    }

    function getMaxUtilizationPercentage() public pure returns (uint256) {
        return MAX_UTILIZATION_PERCENTAGE;
    }

    function getMaxUtilizationPercentageDecimals() public pure returns (uint256) {
        return MAX_UTILIZATION_PERCENTAGE_DECIMALS;
    }

    function _calculateUserLeverage(uint256 _size, address _user) internal view returns (uint256 userLeverage) {
        uint256 priceFeed = getPriceFeed();

        if (userToPositionIds[_user].length() == 0) {
            return (_size.mulDiv(priceFeed, collateral[_user])) / (PRICE_FEED_DECIMALS - USDC_DECIMALS);
        }
        //TODO: Add support for more orders from the same user. For now we block it.
        uint256 positionId = userToPositionIds[_user].at(0);
        Position memory position = positions[positionId];
        int256 userPnl = _calculateUserPnl(positionId, position.isLong);

        if (userPnl == 0) {
            return (_size.mulDiv(priceFeed, collateral[msg.sender])) / (PRICE_FEED_DECIMALS - USDC_DECIMALS);
        }
        if (userPnl > 0) {
            userLeverage = (_size.mulDiv(priceFeed, collateral[msg.sender] + uint256(userPnl)))
                / (PRICE_FEED_DECIMALS - USDC_DECIMALS);
        }
        if (userPnl < 0) {
            uint256 unsignedPnl = SignedMath.abs(userPnl);
            userLeverage =
                (_size.mulDiv(priceFeed, collateral[msg.sender] - unsignedPnl)) / (PRICE_FEED_DECIMALS - USDC_DECIMALS);
        }
    }

    function _calculateUserPnl(uint256 _positionId, bool _isLong) internal view returns (int256 pnl) {
        uint256 currentPrice = getPriceFeed();
        uint256 averagePrice = getAverageOpenPrice(_positionId);
        Position storage position = positions[_positionId];

        if (_isLong) {
            pnl = int256(currentPrice - averagePrice) * int256(position.size);
        } else if (!_isLong) {
            pnl = int256(averagePrice - currentPrice) * int256(position.size);
        } else {
            revert PerpetuEx__NoPositionChosen();
        }
    }

    function maxWithdraw(address owner) public view override returns (uint256 maxWithdrawAllowed) {
        uint256 ownerAssets = super._convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 updatedLiquidity = _updatedLiquidity();
        if (ownerAssets >= updatedLiquidity) {
            return maxWithdrawAllowed = updatedLiquidity;
        }

        if (ownerAssets < updatedLiquidity) {
            return maxWithdrawAllowed = ownerAssets;
        }
    }

    function maxRedeem(address owner) public view override returns (uint256 maxRedeemAllowed) {
        uint256 ownerAssets = super._convertToAssets(balanceOf(owner), Math.Rounding.Floor);

        uint256 updatedLiquidity = _updatedLiquidity();

        if (ownerAssets >= updatedLiquidity) {
            uint256 maxAssetsAllowed = updatedLiquidity;
            return maxRedeemAllowed = super._convertToShares(maxAssetsAllowed, Math.Rounding.Floor);
        }

        if (ownerAssets < updatedLiquidity) {
            return maxRedeemAllowed = super._convertToShares(ownerAssets, Math.Rounding.Floor);
        }
    }

    function totalAssets() public view override returns (uint256 assets) {
        //assuming 1 usdc = $1
        if (s_totalPnl >= 0) {
            uint256 totalPnl = uint256(s_totalPnl);
            assets = s_totalLiquidityDeposited - totalPnl;
        }
        if (s_totalPnl < 0) {
            uint256 totalPnl = SignedMath.abs(s_totalPnl);
            assets = s_totalLiquidityDeposited + totalPnl;
        }
    }
}
