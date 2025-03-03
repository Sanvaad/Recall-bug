// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/GatewayDiamond.sol";
import "../src/interfaces/IDiamond.sol";
import "../src/structs/Subnet.sol";
import "../src/lib/LibGateway.sol";

contract GenesisValidatorTest is Test {
    event MembershipUpdated(Membership);

    function test_DeployWithNoValidators() public {
        IDiamond.FacetCut[] memory diamondCut = new IDiamond.FacetCut[](0);

        SubnetID memory subnetId = SubnetID({root: 0, route: new address[](0)});

        GatewayDiamond.ConstructorParams memory params = GatewayDiamond.ConstructorParams({
            bottomUpCheckPeriod: 100,
            activeValidatorsLimit: 5,
            majorityPercentage: 51,
            networkName: subnetId,
            genesisValidators: new Validator[](0), // empty array, should be invalid
            commitSha: bytes32("test")
        });

        vm.expectEmit(true, true, true, true);
        emit MembershipUpdated(Membership({configurationNumber: 0, validators: new Validator[](0)}));

        GatewayDiamond gateway = new GatewayDiamond(diamondCut, params);

        // The contract deploys successfully with zero validators
        // This is problematic becayse a subnet without validators cannot function
    }
}
