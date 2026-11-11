// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {EnumerableSet} from "@openzeppelin-contracts/utils/structs/EnumerableSet.sol";

/**
 * @title RedemptionClaimTokenStorageLib
 * @author Blueprint Finance
 * @notice EIP-7201 namespaced storage for {RedemptionClaimToken}.
 */
library RedemptionClaimTokenStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("concrete.storage.RedemptionClaimToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant REDEMPTION_CLAIM_TOKEN_STORAGE_LOCATION =
        0x71ce9f29192a538188ba37403461a2673bde9a9f2d1ba645bd6ff753832d4d00;

    struct Storage {
        /// @notice Token decimals, configurable at initialization (defaults to 18).
        uint8 decimalsValue;
        /// @notice Set of addresses permitted to send/receive the token.
        EnumerableSet.AddressSet whitelist;
    }

    function fetch() internal pure returns (Storage storage $) {
        assembly {
            $.slot := REDEMPTION_CLAIM_TOKEN_STORAGE_LOCATION
        }
    }

    function storageLocation() internal pure returns (bytes32) {
        return REDEMPTION_CLAIM_TOKEN_STORAGE_LOCATION;
    }
}
