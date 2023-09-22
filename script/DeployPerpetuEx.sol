// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {PerpetuEx} from "../src/PerpetuEx.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DeployPerpetuEx is Script {
    function run() external returns (PerpetuEx, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (address priceFeed, IERC20 usdc) = helperConfig.activeNetworkConfig();
        vm.startBroadcast();
        PerpetuEx perpetuex = new PerpetuEx(priceFeed, usdc);
        vm.stopBroadcast();
        return (perpetuex, helperConfig);
    }
}
