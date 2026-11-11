// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EscrowVault} from "../../src/EscrowVault.sol";
import {VerdictExecutor} from "../../src/VerdictExecutor.sol";
import {AppealCourt} from "../../src/AppealCourt.sol";
import {IEscrowVault} from "../../src/interfaces/IEscrowVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {SigUtils} from "./SigUtils.sol";

abstract contract BaseTest is Test {
    uint16 internal constant FEE_BPS = 20; // 0.2%
    uint128 internal constant MAX_ESCROW = 1_000_000e6;
    uint128 internal constant MAX_TOTAL = 10_000_000e6;
    uint128 internal constant AMOUNT = 1_000e6;
    bytes32 internal constant TERMS = keccak256("terms");
    bytes32 internal constant REASONING = keccak256("reasoning");

    MockUSDC internal usdc;
    EscrowVault internal vault;
    VerdictExecutor internal exec;
    AppealCourt internal court;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal stranger = makeAddr("stranger");
    address internal provider;
    uint256 internal providerPk;
    address internal signer;
    uint256 internal signerPk;

    uint256 internal nextNonce;

    function setUp() public virtual {
        (provider, providerPk) = makeAddrAndKey("provider");
        (signer, signerPk) = makeAddrAndKey("signer");
        usdc = new MockUSDC();

        // Same circular wiring as script/Deploy.s.sol: executor and court need the vault address up front.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        exec = new VerdictExecutor(predicted, signer, owner);
        court = new AppealCourt(IERC20(address(usdc)), IEscrowVault(predicted), treasury, owner);
        vault = new EscrowVault(
            IERC20(address(usdc)), treasury, address(exec), address(court), FEE_BPS, MAX_ESCROW, MAX_TOTAL, owner
        );
        require(address(vault) == predicted, "vault address prediction failed");
    }

    // ---------------------------------------------------------------- helpers

    function _fee(uint256 amount) internal pure returns (uint256) {
        return (amount * FEE_BPS) / 10_000;
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _acceptSig(
        uint256 pk,
        address _client,
        address _provider,
        uint128 amount,
        uint48 deadline,
        bytes32 terms,
        uint256 nonce
    ) internal view returns (bytes memory) {
        return _sign(pk, SigUtils.acceptDigest(address(vault), _client, _provider, amount, deadline, terms, nonce));
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _create(uint128 amount, uint48 deadline) internal returns (uint256 id) {
        uint256 nonce = nextNonce++;
        bytes memory sig = _acceptSig(providerPk, client, provider, amount, deadline, TERMS, nonce);
        _fund(client, amount + _fee(amount));
        vm.prank(client);
        id = vault.createAgreement(provider, amount, deadline, TERMS, nonce, sig);
    }

    function _create() internal returns (uint256) {
        return _create(AMOUNT, uint48(block.timestamp + 30 days));
    }

    /// @dev Funded -> Delivered -> Disputed.
    function _createDisputed(uint128 amount) internal returns (uint256 id) {
        id = _create(amount, uint48(block.timestamp + 30 days));
        vm.prank(provider);
        vault.markDelivered(id);
        vm.prank(client);
        vault.openDispute(id);
    }

    function _verdict(uint256 id, uint8 round, uint8 pct)
        internal
        view
        returns (VerdictExecutor.Verdict memory v, bytes memory sig)
    {
        v = VerdictExecutor.Verdict({
            agreementId: id,
            round: round,
            clientPct: pct,
            reasoningHash: REASONING,
            validUntil: uint48(block.timestamp + 1 hours)
        });
        sig = _sign(signerPk, SigUtils.verdictDigest(address(exec), id, round, pct, REASONING, v.validUntil));
    }

    function _rule(uint256 id, uint8 round, uint8 pct) internal {
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, round, pct);
        exec.submitVerdict(v, sig);
    }

    function _appeal(uint256 id, address who) internal returns (uint256 bond) {
        (,, uint128 amount) = vault.parties(id);
        bond = court.bondFor(amount);
        usdc.mint(who, bond);
        vm.startPrank(who);
        usdc.approve(address(court), bond);
        court.appeal(id);
        vm.stopPrank();
    }

    function _state(uint256 id) internal view returns (EscrowVault.State) {
        return vault.getAgreement(id).state;
    }
}
