// SPDX-License-Identifier:MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "./BaseSmartWallet.sol";

/* solhint-disable no-inline-assembly */
/* solhint-disable avoid-low-level-calls */

contract BoltzSmartWallet is BaseSmartWallet {
    function _payFees(
        address tokenContract,
        address feesReceiver,
        uint256 tokenAmount,
        uint256 tokenGas,
        string memory errorMessage
    ) internal {
        bool success;
        bytes memory ret;

        if (tokenContract == address(0)) {
            (success, ret) = payable(feesReceiver).call{
                value: tokenAmount,
                gas: tokenGas
            }("");
        } else {
            (success, ret) = tokenContract.call{gas: tokenGas}(
                abi.encodeWithSelector(
                    hex"a9059cbb", // transfer(address,uint256)
                    feesReceiver,
                    tokenAmount
                )
            );
        }

        require(
            success && (ret.length == 0 || abi.decode(ret, (bool))),
            errorMessage
        );
    }

    function _executeTarget(
        address to,
        uint256 value,
        uint256 gasLimit,
        bytes memory data
    ) internal returns (bool success, bytes memory ret) {
        if (gasLimit == 0) {
            return to.call{value: value}(data);
        }

        return to.call{gas: gasLimit, value: value}(data);
    }

    function _revertWithReturnData(
        bytes memory ret,
        string memory errorMessage
    ) internal pure {
        if (ret.length == 0) revert(errorMessage);
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }

    function execute(
        bytes32 suffixData,
        ForwardRequest memory req,
        address feesReceiver,
        bytes calldata sig
    )
        external
        payable
        virtual
        override
        returns (bool success, bytes memory ret)
    {
        (sig);
        require(msg.sender == req.relayHub, "Invalid caller");

        _verifySig(suffixData, req, sig);
        /* solhint-disable not-rely-on-time */
        require(
            req.validUntilTime == 0 || req.validUntilTime > block.timestamp,
            "SW: request expired"
        );
        /* solhint-enable not-rely-on-time */
        nonce++;

        (success, ret) = req.to.call{gas: req.gas, value: req.value}(req.data);

        if (req.tokenAmount > 0) {
            _payFees(
                req.tokenContract,
                feesReceiver,
                req.tokenAmount,
                req.tokenGas,
                "Unable to pay for relay"
            );
        }

        //If any balance has been added then trasfer it to the owner EOA
        if (address(this).balance > 0) {
            //can't fail: req.from signed (off-chain) the request, so it must be an EOA...
            payable(req.from).transfer(address(this).balance);
        }
    }

    /**
     * This Proxy will first charge for the deployment and then it will pass the
     * initialization scope to the wallet logic.
     * This function can only be called once, and it is called by the Factory during deployment
     * @param owner - The EOA that will own the smart wallet
     * @param tokenContract - Token used for payment of the deploy
     * @param feesReceiver - Recipient of payment
     * @param tokenAmount - Amount to pay
     * @param tokenGas - Gas limit of payment
     * @param to - Destination contract to execute
     * @param value - Value to send to destination contract
     * @param gasLimit - Gas limit to forward to destination contract execution
     * @param data - Data to be execute by destination contract
     */
    function initialize(
        address owner,
        address tokenContract,
        address feesReceiver,
        uint256 tokenAmount,
        uint256 tokenGas,
        address to,
        uint256 value,
        uint256 gasLimit,
        bytes calldata data
    ) external {
        require(getOwner() == bytes32(0), "Already initialized");

        _setOwner(owner);

        // Although this check isn't strictly necessary, it's included to improve the transaction estimation
        if (to != address(0)) {
            (bool success, bytes memory ret) = _executeTarget(
                to,
                value,
                gasLimit,
                data
            );
            if (!success) {
                _revertWithReturnData(ret, "Unable to execute");
            }
        }

        if (tokenAmount > 0) {
            _payFees(
                tokenContract,
                feesReceiver,
                tokenAmount,
                tokenGas,
                "Unable to pay for deployment"
            );
        }

        _buildDomainSeparator();

        //If any balance has been added then trasfer it to the owner EOA
        if (address(this).balance > 0) {
            //can't fail: req.from signed (off-chain) the request, so it must be an EOA...
            payable(owner).transfer(address(this).balance);
        }
    }
}
