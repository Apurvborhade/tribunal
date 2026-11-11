// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IEscrowVault} from "./interfaces/IEscrowVault.sol";

contract VerdictExecutor is EIP712, Ownable2Step {
    struct Verdict {
        uint256 agreementId;
        uint8 round;
        uint8 clientPct;
        bytes32 reasoningHash;
        uint48 validUntil;
    }
    bytes32 public constant VERDICT_TYPEHASH =
        keccak256("Verdict(uint256 agreementId,uint8 round,uint8 clientPct,bytes32 reasoningHash,uint48 validUntil)");
    uint48 public constant SIGNER_DELAY = 72 hours;

    IEscrowVault public immutable vault;
    address public signer;
    address public pendingSigner;
    uint48 public pendingSignerEta;

    error NoSigner();
    error Expired();
    error BadSignature();
    error NotReady();
    error BadParams();

    event VerdictSubmitted(uint256 indexed id, uint8 round, uint8 clientPct, address indexed relayer);
    event SignerProposed(address indexed signer, uint48 eta);
    event SignerChanged(address indexed signer);
    event SignerRevoked();

    constructor(address _vault, address _signer, address _owner) EIP712("TribunalVerdict", "1") Ownable(_owner) {
        vault = IEscrowVault(_vault);
        signer = _signer;
    }

    function submitVerdict(Verdict calldata verdict, bytes calldata signature) external {
        if (signer == address(0)) revert NoSigner();
        if (block.timestamp > verdict.validUntil) revert Expired();
        if (verdict.clientPct > 100) revert BadParams();

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VERDICT_TYPEHASH,
                    verdict.agreementId,
                    verdict.round,
                    verdict.clientPct,
                    verdict.reasoningHash,
                    verdict.validUntil
                )
            )
        );
        address recoveredSigner = ECDSA.recover(digest, signature);
        if (recoveredSigner != signer) revert BadSignature();

        (IEscrowVault.State state,,,) = vault.rulingInfo(verdict.agreementId);
        bool ready = (verdict.round == 1 && state == IEscrowVault.State.Disputed)
            || (verdict.round == 2 && state == IEscrowVault.State.Appealed);
        if (!ready) revert NotReady();

        vault.recordRuling(verdict.agreementId, verdict.round, verdict.clientPct, verdict.reasoningHash);
        emit VerdictSubmitted(verdict.agreementId, verdict.round, verdict.clientPct, msg.sender);
    }

    // Signer rotation: slow to replace, instant to switch off.
    function proposeSigner(address s) external onlyOwner {
        if (s == address(0)) revert BadParams();
        pendingSigner = s;
        pendingSignerEta = uint48(block.timestamp) + SIGNER_DELAY;
        emit SignerProposed(s, pendingSignerEta);
    }

    function applySigner() external {
        if (pendingSigner == address(0) || block.timestamp < pendingSignerEta) revert NotReady();
        signer = pendingSigner;
        pendingSigner = address(0);
        pendingSignerEta = 0;
        emit SignerChanged(signer);
    }

    function revokeSigner() external onlyOwner {
        signer = address(0);
        pendingSigner = address(0);
        pendingSignerEta = 0;
        emit SignerRevoked();
    }
}

