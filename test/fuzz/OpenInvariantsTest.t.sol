// SPDX-License-Identifier: MIT

// Have our Invariants aka properties

// What are our invariants?

// 1. The Total supply of DSC should be less than the total value of collateral

// 2 . Getter view Functions should never revert <- evergreen invariant

pragma solidity 0.8.21;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract OpenInvariantsTest is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    DeployDSC deployer;
    address weth;
    address wbtc;

    function setUp() external {
        console.log("started");
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        targetContract(address(dsce));
        console.log("finished");
    }

    // function invariant_protocolMustHaveMoreValueThanTotalSupplys() public view {
    //     // get the value of all the collateral in tthe protocol

    //     console.log("Started test");
    //     // compare it to all the debt(dsc)
    //     uint256 totalSupply = dsc.totalSupply();
    //     uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(dsce));
    //     uint256 totalBtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

    //     uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
    //     uint256 wbtcValue = dsce.getUsdValue(wbtc, totalBtcDeposited);

    //     console.log("weth value: ", wethValue);
    //     console.log("wbtc value :", wbtcValue);
    //     console.log("Total supply :", totalSupply);

    //     assert((wethValue + wbtcValue) >= totalSupply);
    //     console.log("finsied tesy");
    // }
}
