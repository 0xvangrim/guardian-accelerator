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
    struct Position {
        uint256 positionId;
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
    uint256 private constant MAX_LEVERAGE = 20 * 10 ** 4;
    uint256 private constant DECIMALS_DELTA = 10 ** 12; // btc decimals - usdc decimals
    uint256 private constant DECIMALS_PRECISION = 10 ** 4; // to avoid truncation precision loss (leverage calculation)
    uint16 private constant DEAD_SHARES = 1000;

    uint256 private s_nonce;
    uint256 public s_totalLiquidityDeposited;
    int256 public s_totalPnl;
    uint256 public s_shortOpenInterest;
    uint256 public s_longOpenInterestInTokens;

    constructor(address priceFeed, IERC20 _usdc) ERC4626(_usdc) ERC20("PerpetuEx", "PXT") {
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_usdc = IERC20(_usdc);

        //Avoiding the inflation attack by sending shares to the shadow realm
        // _mint(address(0), DEAD_SHARES);
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
        s_totalLiquidityDeposited += assets;
        shares = super.deposit(assets, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        s_totalLiquidityDeposited -= assets;
        shares = super.withdraw(assets, receiver, owner);
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
        uint256 currentPositionId = ++s_nonce;
        uint256 currentPrice = getPriceFeed();
        Position memory newPosition = Position({
            positionId: currentPositionId,
            size: _size,
            collateral: collateral[msg.sender],
            totalValue: _size * currentPrice,
            owner: msg.sender,
            isLong: _isLong
        });
        // check that s_shortOpenInterest + s_longOpenInterestInTokens < 80% of total assets
        // Update the actual open interests
        _updateOpenInterests(_isLong, _size, currentPrice, PositionAction.Open);

        uint256 updatedLiquidity = _updatedLiquidity();
        if (s_shortOpenInterest + (s_longOpenInterestInTokens * currentPrice) >= updatedLiquidity * DECIMALS_DELTA) {
            revert PerpetuEx__InsufficientLiquidity();
        }

        // _updateOpenInterests(_isLong, _size, currentPrice, PositionAction.Open);
        positions[currentPositionId] = newPosition;
        userToPositionIds[msg.sender].add(currentPositionId);
    }

    function closePosition(uint256 _positionId) external {
        Position storage position = positions[_positionId];
        if (position.positionId == 0) revert PerpetuEx__InvalidPositionId();
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

        // check that s_shortOpenInterest + s_longOpenInterestInTokens < 80% of total assets
        _updateOpenInterests(position.isLong, _size, currentPrice, PositionAction.Open);
        // _updateOpenInterestsIncrease(position.isLong, _size, currentPrice);

        uint256 updatedLiquidity = _updatedLiquidity();
        if (s_shortOpenInterest + (s_longOpenInterestInTokens * currentPrice) >= updatedLiquidity * DECIMALS_DELTA) {
            revert PerpetuEx__InsufficientLiquidity();
        }

        // Calculate the total USD value of the new position being added
        uint256 addedValue = _size * currentPrice;
        // Update s_longOpenInterestInTokens if long or s_shortOpenInterest if short
        // _updateOpenInterests(position.isLong, _size, currentPrice, PositionAction.Open);
        // Update the total value and size of the order
        position.totalValue += addedValue;
        position.size += _size;
    }

    function decreaseSize(uint256 _positionId, uint256 _sizeDelta) external {
        Position storage position = positions[_positionId];
        uint256 currentPrice = getPriceFeed();
        if (position.owner != msg.sender) revert PerpetuEx__NotOwner();
        if (_sizeDelta == 0 || _sizeDelta >= position.size) {
            revert PerpetuEx__InvalidSize();
        }
        // Update open interests
        _updateOpenInterestsDecrease(position.isLong, _sizeDelta, currentPrice);

        // compute pnl for user and add to total pnl
        int256 pnl = _calculateUserPnl(_positionId, position.isLong);
        //update total pnl
        s_totalPnl += pnl;
        _updatedLiquidity();

        uint256 averagePrice = getAverageOpenPrice(_positionId);
        if (pnl >= 0) {
            // send profits to user
            uint256 profits = uint256(pnl);
            position.size -= _sizeDelta;
            //TODO: make sure I should use averagePrice or currentPrice
            position.totalValue -= _sizeDelta * averagePrice;
            i_usdc.safeTransfer(msg.sender, profits);
        } else if (pnl < 0) {
            uint256 unsignedPnl = SignedMath.abs(pnl);
            position.size -= _sizeDelta;
            position.totalValue -= _sizeDelta * averagePrice;
            collateral[msg.sender] -= unsignedPnl;
            // check new leverage even if it should be fine
            if (_calculateUserLeverage(position.size - _sizeDelta, msg.sender) > MAX_LEVERAGE) {
                revert PerpetuEx__InvalidSize();
            }
        }
    }

    function increaseCollateral(uint256 _positionId, uint256 _collateral) external {
        Position storage position = positions[_positionId];
        if (_collateral == 0) revert PerpetuEx__InvalidCollateral();
        if (position.owner != msg.sender) revert PerpetuEx__NotOwner();
        position.collateral += _collateral;
        i_usdc.safeTransferFrom(msg.sender, address(this), _collateral);
    }

    function decreaseCollateral(uint256 _amount) external {
        if (collateral[msg.sender] < _amount) {
            revert PerpetuEx__InsufficientCollateral();
        }
        if (_amount == 0) revert PerpetuEx__InvalidAmount();

        // calculate leverage after collateral decrease
        uint256 userCollateral = collateral[msg.sender];
        collateral[msg.sender] = userCollateral - _amount;
        Position memory position = positions[userToPositionIds[msg.sender].at(0)];
        uint256 size = position.size;
        uint256 updatedLeverage = _calculateUserLeverage(size, msg.sender);
        // check if leverage is above 20x
        if (updatedLeverage > MAX_LEVERAGE) {
            revert PerpetuEx__InvalidAmount();
        }
        i_usdc.safeTransfer(msg.sender, _amount);
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
            return updatedLiquidity;
        }
        if (s_totalPnl < 0) {
            updatedLiquidity = liquidityReserveRestriction + totalPnl;
            return updatedLiquidity;
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

    // TODO: refactor by implementing this logic inside _updateOpenInterests using string literals
    function _updateOpenInterestsDecrease(bool _isLong, uint256 _sizeDelta, uint256 _price) internal {
        if (_isLong) {
            s_longOpenInterestInTokens -= _sizeDelta;
        } else if (!_isLong) {
            uint256 valueChange = _sizeDelta * _price;
            s_shortOpenInterest -= valueChange;
        } else {
            revert PerpetuEx__NoPositionChosen();
        }
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
        if (positions[_positionId].positionId == 0) revert PerpetuEx__InvalidPositionId();
        return position.totalValue / position.size;
    }

    function _calculateUserLeverage(uint256 _size, address _user) internal view returns (uint256 userLeverage) {
        uint256 priceFeed = getPriceFeed();
        uint256 priceFeedPrecisionAdjusted = priceFeed * DECIMALS_PRECISION;

        uint256 userCollateral = collateral[_user] * DECIMALS_DELTA;
        if (userToPositionIds[_user].length() == 0) {
            userLeverage = _size.mulDiv(priceFeedPrecisionAdjusted, userCollateral);
            return userLeverage;
        }
        //TODO: Add support for more orders from the same user. For now we block it.
        uint256 positionId = userToPositionIds[_user].at(0);
        Position memory position = positions[positionId];
        int256 userPnl = _calculateUserPnl(position.positionId, position.isLong);

        if (userPnl == 0) {
            userLeverage = _size.mulDiv(priceFeedPrecisionAdjusted, userCollateral);
            return userLeverage;
        }
        if (userPnl > 0) {
            userLeverage = (_size.mulDiv(priceFeedPrecisionAdjusted, userCollateral + uint256(userPnl)));
            return userLeverage;
        }
        if (userPnl < 0) {
            uint256 unsignedPnl = SignedMath.abs(userPnl);
            userLeverage = (_size.mulDiv(priceFeedPrecisionAdjusted, userCollateral - unsignedPnl));
            return userLeverage;
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

    function getLeverage(address _user) public view returns (uint256 leverage) {
        Position memory position = positions[userToPositionIds[_user].at(0)];
        uint256 size = position.size;
        leverage = _calculateUserLeverage(size, _user);
    }
}
