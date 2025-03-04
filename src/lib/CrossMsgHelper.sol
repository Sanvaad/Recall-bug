// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity ^0.8.23;

import {METHOD_SEND, EMPTY_BYTES} from "../constants/Constants.sol";
import {IpcEnvelope, ResultMsg, CallMsg, IpcMsgKind, OutcomeType} from "../structs/CrossNet.sol";
import {IPCMsgType} from "../enums/IPCMsgType.sol";
import {SubnetID, IPCAddress} from "../structs/Subnet.sol";
import {SubnetIDHelper} from "../lib/SubnetIDHelper.sol";
import {FvmAddressHelper} from "../lib/FvmAddressHelper.sol";
import {LibGateway} from "../lib/LibGateway.sol";
import {FvmAddress} from "../structs/FvmAddress.sol";
import {FilAddress} from "../../node_modules/fevmate/contracts/utils/FilAddress.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Asset} from "../structs/Subnet.sol";
import {AssetHelper} from "./AssetHelper.sol";
import {IIpcHandler} from "../sdk/interfaces/IIpcHandler.sol";
// solhint-disable-next-line no-global-import
import "../errors/IPCErrors.sol";

/// @title Helper library for manipulating IpcEnvelope-related structs
library CrossMsgHelper {
    using SubnetIDHelper for SubnetID;
    using FilAddress for address;
    using FvmAddressHelper for FvmAddress;
    using AssetHelper for Asset;

    error CannotExecuteEmptyEnvelope();

    function createTransferMsg(IPCAddress memory from, IPCAddress memory to, uint256 value)
        public
        pure
        returns (IpcEnvelope memory)
    {
        return IpcEnvelope({
            kind: IpcMsgKind.Transfer,
            from: from,
            to: to,
            value: value,
            message: EMPTY_BYTES,
            originalNonce: 0,
            localNonce: 0
        });
    }

    function createCallMsg(
        IPCAddress memory from,
        IPCAddress memory to,
        uint256 value,
        bytes4 method,
        bytes memory params
    ) public pure returns (IpcEnvelope memory) {
        CallMsg memory message = CallMsg({method: abi.encodePacked(method), params: params});
        return IpcEnvelope({
            kind: IpcMsgKind.Call,
            from: from,
            to: to,
            value: value,
            message: abi.encode(message),
            originalNonce: 0,
            localNonce: 0
        });
    }

    /// @notice Creates a receipt message for the given envelope.
    /// It reverts the from and to to return to the original sender
    /// and identifies the receipt through the hash of the original message.
    function createResultMsg(IpcEnvelope calldata crossMsg, OutcomeType outcome, bytes memory ret)
        public
        pure
        returns (IpcEnvelope memory)
    {
        ResultMsg memory message = ResultMsg({id: toTracingId(crossMsg), outcome: outcome, ret: ret});

        uint256 value = crossMsg.value;
        // if the message was executed successfully, the value stayed
        // in the subnet and there's no need to return it.
        if (outcome == OutcomeType.Ok) {
            value = 0;
        }
        return IpcEnvelope({
            kind: IpcMsgKind.Result,
            from: crossMsg.to,
            to: crossMsg.from,
            value: value,
            message: abi.encode(message),
            originalNonce: 0,
            localNonce: 0
        });
    }

    // creates transfer message from the child subnet to the parent subnet
    function createReleaseMsg(SubnetID calldata subnet, address signer, FvmAddress calldata to, uint256 value)
        public
        pure
        returns (IpcEnvelope memory)
    {
        return createTransferMsg(
            IPCAddress({subnetId: subnet, rawAddress: FvmAddressHelper.from(signer)}),
            IPCAddress({subnetId: subnet.getParentSubnet(), rawAddress: to}),
            value
        );
    }

    // creates transfer message from the parent subnet to the child subnet
    function createFundMsg(SubnetID calldata subnet, address signer, FvmAddress calldata to, uint256 value)
        public
        pure
        returns (IpcEnvelope memory)
    {
        return createTransferMsg(
            IPCAddress({subnetId: subnet.getParentSubnet(), rawAddress: FvmAddressHelper.from(signer)}),
            IPCAddress({subnetId: subnet, rawAddress: to}),
            value
        );
    }

    function applyType(IpcEnvelope calldata message, SubnetID calldata currentSubnet)
        public
        pure
        returns (IPCMsgType)
    {
        SubnetID memory toSubnet = message.to.subnetId;
        SubnetID memory fromSubnet = message.from.subnetId;
        SubnetID memory currentParentSubnet = currentSubnet.commonParent(toSubnet);
        SubnetID memory messageParentSubnet = fromSubnet.commonParent(toSubnet);

        if (currentParentSubnet.equals(messageParentSubnet)) {
            if (fromSubnet.route.length > messageParentSubnet.route.length) {
                return IPCMsgType.BottomUp;
            }
        }

        return IPCMsgType.TopDown;
    }

    function toHash(IpcEnvelope memory crossMsg) internal pure returns (bytes32) {
        return keccak256(abi.encode(crossMsg));
    }

    function toHash(IpcEnvelope[] memory crossMsgs) public pure returns (bytes32) {
        return keccak256(abi.encode(crossMsgs));
    }

    /// @notice Returns a deterministic hash for the given cross message, excluding the nonce,
    /// which is useful for generating a `tracingId` for cross messages.
    function toTracingId(IpcEnvelope memory crossMsg) internal pure returns (bytes32) {
        return keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encode(
                crossMsg.kind, crossMsg.to, crossMsg.from, crossMsg.value, crossMsg.message, crossMsg.originalNonce
            )
        );
    }

    function isEmpty(IpcEnvelope memory crossMsg) internal pure returns (bool) {
        // envelopes need to necessarily include a message inside except
        // if it is a plain `Transfer`.
        if (crossMsg.kind == IpcMsgKind.Transfer) {
            return crossMsg.value == 0;
        }
        return crossMsg.message.length == 0;
    }

    /// @notice Executes a cross message envelope.
    ///
    /// This function doesn't revert except if the envelope is empty.
    /// It returns a success flag and the return data for the success or
    /// the error so it can be returned to the sender through a cross-message receipt.
    /// NOTE: Execute assumes that the fund it is handling have already been
    /// released for their use so they can be conveniently included in the
    /// forwarded message, or the receipt in the case of failure.
    function execute(IpcEnvelope calldata crossMsg, Asset memory supplySource)
        public
        returns (bool success, bytes memory ret)
    {
        if (isEmpty(crossMsg)) {
            revert CannotExecuteEmptyEnvelope();
        }

        address recipient = crossMsg.to.rawAddress.extractEvmAddress().normalize();
        if (crossMsg.kind == IpcMsgKind.Transfer) {
            return supplySource.transferFunds({recipient: payable(recipient), value: crossMsg.value});
        } else if (crossMsg.kind == IpcMsgKind.Call || crossMsg.kind == IpcMsgKind.Result) {
            // For a Result message, the idea is to perform a call as this returns control back to the caller.
            // If it's an account, there will be no code to invoke, so this will be have like a bare transfer.
            // But if the original caller was a contract, this give it control so it can handle the result

            // send the envelope directly to the entrypoint
            // use supplySource so the tokens in the message are handled successfully
            // and by the right supply source
            return supplySource.performCall(
                payable(recipient), abi.encodeCall(IIpcHandler.handleIpcMessage, (crossMsg)), crossMsg.value
            );
        }
        return (false, EMPTY_BYTES);
    }

    // checks whether the cross messages are sorted in ascending order or not
    function isSorted(IpcEnvelope[] calldata crossMsgs) external pure returns (bool) {
        uint256 prevNonce;
        uint256 length = crossMsgs.length;
        for (uint256 i; i < length;) {
            uint256 nonce = crossMsgs[i].localNonce;

            if (prevNonce >= nonce) {
                // gas-opt: original check: i > 0
                if (i != 0) {
                    return false;
                }
            }

            prevNonce = nonce;
            unchecked {
                ++i;
            }
        }

        return true;
    }

    function validateCrossMessage(IpcEnvelope memory crossMsg)
        internal
        view
        returns (bool, InvalidXnetMessageReason, IPCMsgType)
    {
        return LibGateway.checkCrossMessage(crossMsg);
    }
}
