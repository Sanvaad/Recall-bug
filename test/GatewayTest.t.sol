// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/GatewayDiamond.sol";
import "../src/interfaces/IDiamond.sol";
import "../src/structs/Subnet.sol";
import "../src/lib/LibGateway.sol";

contract GatewayDiamondTest is Test {
    /* ///////////////////////////////////////////////////////////////////////
     Test demonstrates the lack of validation for activeValidatorsLimit 
    /////////////////////////////////////////////////////////////////////// */

    function test_ZeroActiveValidatorsLimit() public {
        IDiamond.FacetCut[] memory diamondCut = new IDiamond.FacetCut[](0);

        SubnetID memory subnetId = SubnetID({root: 0, route: new address[](0)});

        Validator[] memory genesisValidators = new Validator[](1);

        genesisValidators[0] = Validator({addr: address(1), weight: 100, metadata: bytes("")});

        GatewayDiamond.ConstructorParams memory params = GatewayDiamond.ConstructorParams({
            bottomUpCheckPeriod: 100,
            activeValidatorsLimit: 0, // deliberately set to which should be invalid
            majorityPercentage: 51,
            networkName: subnetId,
            genesisValidators: genesisValidators,
            commitSha: bytes32("test")
        });

        // Deploy the contract, and it does not revert despite invalid activeValidatorsLimit

        GatewayDiamond gatewayInstance = new GatewayDiamond(diamondCut, params);
    }
}
