// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Independent EIP-712 digest construction, so tests don't just trust the contracts' own hashing.
library SigUtils {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant ACCEPT_TYPEHASH = keccak256(
        "Accept(address client,address provider,uint128 amount,uint48 deadline,bytes32 termsHash,uint256 nonce)"
    );
    bytes32 internal constant VERDICT_TYPEHASH =
        keccak256("Verdict(uint256 agreementId,uint8 round,uint8 clientPct,bytes32 reasoningHash,uint48 validUntil)");

    function domainSeparator(string memory name, address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256(bytes("1")), block.chainid, verifyingContract)
        );
    }

    function typedDigest(bytes32 domain, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function acceptDigest(
        address vault,
        address client,
        address provider,
        uint128 amount,
        uint48 deadline,
        bytes32 termsHash,
        uint256 nonce
    ) internal view returns (bytes32) {
        return typedDigest(
            domainSeparator("EscrowVault", vault),
            keccak256(abi.encode(ACCEPT_TYPEHASH, client, provider, amount, deadline, termsHash, nonce))
        );
    }

    function verdictDigest(
        address executor,
        uint256 agreementId,
        uint8 round,
        uint8 clientPct,
        bytes32 reasoningHash,
        uint48 validUntil
    ) internal view returns (bytes32) {
        return typedDigest(
            domainSeparator("TribunalVerdict", executor),
            keccak256(abi.encode(VERDICT_TYPEHASH, agreementId, round, clientPct, reasoningHash, validUntil))
        );
    }
}
