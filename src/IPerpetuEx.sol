//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IPerpetuEx {
    /// Errors
    error PerpetuEx__InvalidCollateral();
    error PerpetuEx__InvalidSize();
    error PerpetuEx__InvalidAmount();
    error PerpetuEx__InsufficientCollateral();
    error PerpetuEx__InvalidOrder();
    error PerpetuEx__NotOwner();
    error PerpetuEx__NoPositionChosen();

    enum Position {
        Long,
        Short
    }
}
