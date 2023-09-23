// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployPerpetuEx} from "../../script/DeployPerpetuEx.sol";
import {PerpetuEx} from "../../src/PerpetuEx.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract PerpetuExTest is Test {
    PerpetuEx public perpetuEx;
    HelperConfig public helperConfig;

    function setUp() external {
        DeployPerpetuEx deployer = new DeployPerpetuEx();
        (perpetuEx, helperConfig) = deployer.run();
    }
}
