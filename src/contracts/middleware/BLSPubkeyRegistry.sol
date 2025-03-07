// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "./BLSPubkeyRegistryStorage.sol";
import "../libraries/BN254.sol";

contract BLSPubkeyRegistry is BLSPubkeyRegistryStorage {
    using BN254 for BN254.G1Point;

    /// @notice when applied to a function, only allows the RegistryCoordinator to call it
    modifier onlyRegistryCoordinator() {
        require(
            msg.sender == address(registryCoordinator),
            "BLSPubkeyRegistry.onlyRegistryCoordinator: caller is not the registry coordinator"
        );
        _;
    }

    /// @notice Sets the (immutable) `registryCoordinator` and `pubkeyCompendium` addresses
    constructor(
        IRegistryCoordinator _registryCoordinator, 
        IBLSPublicKeyCompendium _pubkeyCompendium
    ) BLSPubkeyRegistryStorage(_registryCoordinator, _pubkeyCompendium) {}

    /**
     * @notice Registers the `operator`'s pubkey for the specified `quorumNumbers`.
     * @param operator The address of the operator to register.
     * @param quorumNumbers The quorum numbers the operator is registering for, where each byte is an 8 bit integer quorumNumber.
     * @param pubkey The operator's BLS public key.
     * @return pubkeyHash of the operator's pubkey
     * @dev access restricted to the RegistryCoordinator
     * @dev Preconditions (these are assumed, not validated in this contract):
     *         1) `quorumNumbers` has no duplicates
     *         2) `quorumNumbers.length` != 0
     *         3) `quorumNumbers` is ordered in ascending order
     *         4) the operator is not already registered
     */
    function registerOperator(
        address operator,
        bytes memory quorumNumbers,
        BN254.G1Point memory pubkey
    ) external onlyRegistryCoordinator returns (bytes32) {
        _beforeRegisterOperator(operator, quorumNumbers);
        //calculate hash of the operator's pubkey
        bytes32 pubkeyHash = BN254.hashG1Point(pubkey);

        require(pubkeyHash != ZERO_PK_HASH, "BLSPubkeyRegistry.registerOperator: cannot register zero pubkey");
        //ensure that the operator owns their public key by referencing the BLSPubkeyCompendium
        require(
            getOperatorFromPubkeyHash(pubkeyHash) == operator,
            "BLSPubkeyRegistry.registerOperator: operator does not own pubkey"
        );
        // update each quorum's aggregate pubkey
        _processQuorumApkUpdate(quorumNumbers, pubkey);

        _afterRegisterOperator(operator, quorumNumbers);
        // emit event so offchain actors can update their state
        emit OperatorAddedToQuorums(operator, quorumNumbers);
        return pubkeyHash;
    }

    /**
     * @notice Deregisters the `operator`'s pubkey for the specified `quorumNumbers`.
     * @param operator The address of the operator to deregister.
     * @param quorumNumbers The quorum numbers the operator is deregistering from, where each byte is an 8 bit integer quorumNumber.
     * @param pubkey The public key of the operator.
     * @dev access restricted to the RegistryCoordinator
     * @dev Preconditions (these are assumed, not validated in this contract):
     *         1) `quorumNumbers` has no duplicates
     *         2) `quorumNumbers.length` != 0
     *         3) `quorumNumbers` is ordered in ascending order
     *         4) the operator is not already deregistered
     *         5) `quorumNumbers` is a subset of the quorumNumbers that the operator is registered for
     *         6) `pubkey` is the same as the parameter used when registering
     */
    function deregisterOperator(
        address operator,
        bytes memory quorumNumbers,
        BN254.G1Point memory pubkey
    ) external onlyRegistryCoordinator {
        _beforeDeregisterOperator(operator, quorumNumbers);
        bytes32 pubkeyHash = BN254.hashG1Point(pubkey);

        require(
            getOperatorFromPubkeyHash(pubkeyHash) == operator,
            "BLSPubkeyRegistry.registerOperator: operator does not own pubkey"
        );

        // update each quorum's aggregate pubkey
        _processQuorumApkUpdate(quorumNumbers, pubkey.negate());

        _afterDeregisterOperator(operator, quorumNumbers);

        emit OperatorRemovedFromQuorums(operator, quorumNumbers);
    }

    /**
     * @notice Returns the indices of the quorumApks index at `blockNumber` for the provided `quorumNumbers`
     * @dev Returns the current indices if `blockNumber >= block.number`
     */
    function getApkIndicesForQuorumsAtBlockNumber(
        bytes calldata quorumNumbers,
        uint256 blockNumber
    ) external view returns (uint32[] memory) {
        uint32[] memory indices = new uint32[](quorumNumbers.length);
        for (uint i = 0; i < quorumNumbers.length; i++) {
            uint8 quorumNumber = uint8(quorumNumbers[i]);
            uint32 quorumApkUpdatesLength = uint32(quorumApkUpdates[quorumNumber].length);

            if (quorumApkUpdatesLength == 0 || blockNumber < quorumApkUpdates[quorumNumber][0].updateBlockNumber) {
                revert(
                    "BLSPubkeyRegistry.getApkIndicesForQuorumsAtBlockNumber: blockNumber is before the first update"
                );
            }

            for (uint32 j = 0; j < quorumApkUpdatesLength; j++) {
                if (quorumApkUpdates[quorumNumber][quorumApkUpdatesLength - j - 1].updateBlockNumber <= blockNumber) {
                    indices[i] = quorumApkUpdatesLength - j - 1;
                    break;
                }
            }
        }
        return indices;
    }

    /// @notice Returns the current APK for the provided `quorumNumber `
    function getApkForQuorum(uint8 quorumNumber) external view returns (BN254.G1Point memory) {
        return quorumApk[quorumNumber];
    }

    /// @notice Returns the `ApkUpdate` struct at `index` in the list of APK updates for the `quorumNumber`
    function getApkUpdateForQuorumByIndex(uint8 quorumNumber, uint256 index) external view returns (ApkUpdate memory) {
        return quorumApkUpdates[quorumNumber][index];
    }

    /**
     * @notice get hash of the apk of `quorumNumber` at `blockNumber` using the provided `index`;
     * called by checkSignatures in BLSSignatureChecker.sol.
     * @param quorumNumber is the quorum whose ApkHash is being retrieved
     * @param blockNumber is the number of the block for which the latest ApkHash will be retrieved
     * @param index is the index of the apkUpdate being retrieved from the list of quorum apkUpdates in storage
     */
    function getApkHashForQuorumAtBlockNumberFromIndex(
        uint8 quorumNumber,
        uint32 blockNumber,
        uint256 index
    ) external view returns (bytes24) {
        ApkUpdate memory quorumApkUpdate = quorumApkUpdates[quorumNumber][index];
        _validateApkHashForQuorumAtBlockNumber(quorumApkUpdate, blockNumber);
        return quorumApkUpdate.apkHash;
    }

    /// @notice Returns the length of ApkUpdates for the provided `quorumNumber`
    function getQuorumApkHistoryLength(uint8 quorumNumber) external view returns (uint32) {
        return uint32(quorumApkUpdates[quorumNumber].length);
    }

    /// @notice Returns the operator address for the given `pubkeyHash`
    function getOperatorFromPubkeyHash(bytes32 pubkeyHash) public view returns (address) {
        return pubkeyCompendium.pubkeyHashToOperator(pubkeyHash);
    }

    function _processQuorumApkUpdate(bytes memory quorumNumbers, BN254.G1Point memory point) internal {
        BN254.G1Point memory apkAfterUpdate;

        for (uint i = 0; i < quorumNumbers.length; ) {
            uint8 quorumNumber = uint8(quorumNumbers[i]);

            uint256 quorumApkUpdatesLength = quorumApkUpdates[quorumNumber].length;
            if (quorumApkUpdatesLength > 0) {
                // update nextUpdateBlockNumber of the current latest ApkUpdate
                quorumApkUpdates[quorumNumber][quorumApkUpdatesLength - 1].nextUpdateBlockNumber = uint32(block.number);
            }

            apkAfterUpdate = quorumApk[quorumNumber].plus(point);

            //update aggregate public key for this quorum
            quorumApk[quorumNumber] = apkAfterUpdate;
            //create new ApkUpdate to add to the mapping
            ApkUpdate memory latestApkUpdate;
            latestApkUpdate.apkHash = bytes24(BN254.hashG1Point(apkAfterUpdate));
            latestApkUpdate.updateBlockNumber = uint32(block.number);
            quorumApkUpdates[quorumNumber].push(latestApkUpdate);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Hook that is called before any operator registration to insert additional logic.
     * @param operator The address of the operator to register.
     * @param quorumNumbers The quorum numbers the operator is registering for, where each byte is an 8 bit integer quorumNumber.
     */
    function _beforeRegisterOperator(address operator, bytes memory quorumNumbers) internal virtual {}

    /**
     * @dev Hook that is called after any operator registration to insert additional logic.
     * @param operator The address of the operator to register.
     * @param quorumNumbers The quorum numbers the operator is registering for, where each byte is an 8 bit integer quorumNumber.
     */
    function _afterRegisterOperator(address operator, bytes memory quorumNumbers) internal virtual {}

    /**
     * @dev Hook that is called before any operator deregistration to insert additional logic.
     * @param operator The address of the operator to deregister.
     * @param quorumNumbers The quorum numbers the operator is registering for, where each byte is an 8 bit integer quorumNumber.
     */
    function _beforeDeregisterOperator(address operator, bytes memory quorumNumbers) internal virtual {}

    /**
     * @dev Hook that is called after any operator deregistration to insert additional logic.
     * @param operator The address of the operator to deregister.
     * @param quorumNumbers The quorum numbers the operator is registering for, where each byte is an 8 bit integer quorumNumber.
     */
    function _afterDeregisterOperator(address operator, bytes memory quorumNumbers) internal virtual {}

    function _validateApkHashForQuorumAtBlockNumber(ApkUpdate memory apkUpdate, uint32 blockNumber) internal pure {
        require(
            blockNumber >= apkUpdate.updateBlockNumber,
            "BLSPubkeyRegistry._validateApkHashForQuorumAtBlockNumber: index too recent"
        );
        /**
         * if there is a next update, check that the blockNumber is before the next update or if
         * there is no next update, then apkUpdate.nextUpdateBlockNumber is 0.
         */
        require(
            apkUpdate.nextUpdateBlockNumber == 0 || blockNumber < apkUpdate.nextUpdateBlockNumber,
            "BLSPubkeyRegistry._validateApkHashForQuorumAtBlockNumber: not latest apk update"
        );
    }
}
