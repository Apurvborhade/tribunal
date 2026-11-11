// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {VerdictExecutor} from "../src/VerdictExecutor.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SigUtils} from "./utils/SigUtils.sol";

contract VerdictExecutorTest is BaseTest {
    event VerdictSubmitted(uint256 indexed id, uint8 round, uint8 clientPct, address indexed relayer);

    function test_constructor() public view {
        assertEq(address(exec.vault()), address(vault));
        assertEq(exec.signer(), signer);
        assertEq(exec.owner(), owner);
        assertEq(exec.VERDICT_TYPEHASH(), SigUtils.VERDICT_TYPEHASH);
    }

    // =================================================================== submitVerdict

    function test_submit_roundOne_anyoneCanRelay() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, 60);
        vm.expectEmit(address(exec));
        emit VerdictSubmitted(id, 1, 60, stranger);
        vm.prank(stranger);
        exec.submitVerdict(v, sig);
        (EscrowVault.State st,, uint8 pct1,) = vault.rulingInfo(id);
        assertEq(uint8(st), uint8(EscrowVault.State.Ruled));
        assertEq(pct1, 60);
    }

    function test_submit_roundTwo_requiresAppeal() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v2, bytes memory sig2) = _verdict(id, 2, 60);
        vm.expectRevert(VerdictExecutor.NotReady.selector); // Disputed, not Appealed
        exec.submitVerdict(v2, sig2);

        _rule(id, 1, 10);
        vm.expectRevert(VerdictExecutor.NotReady.selector); // Ruled, not Appealed
        exec.submitVerdict(v2, sig2);

        _appeal(id, provider);
        exec.submitVerdict(v2, sig2);
        assertEq(uint8(_state(id)), uint8(EscrowVault.State.Resolved));
    }

    function test_submit_revertsOnReplay() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, 60);
        exec.submitVerdict(v, sig);
        vm.expectRevert(VerdictExecutor.NotReady.selector);
        exec.submitVerdict(v, sig);
    }

    function test_submit_revertsWhenNotDisputed() public {
        uint256 id = _create();
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, 60);
        vm.expectRevert(VerdictExecutor.NotReady.selector);
        exec.submitVerdict(v, sig);
    }

    function test_submit_revertsOnInvalidRound() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 3, 60);
        vm.expectRevert(VerdictExecutor.NotReady.selector);
        exec.submitVerdict(v, sig);
    }

    function test_submit_revertsWhenExpired() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, 60);
        vm.warp(v.validUntil + 1);
        vm.expectRevert(VerdictExecutor.Expired.selector);
        exec.submitVerdict(v, sig);
    }

    function test_submit_revertsOnPctAbove100() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, 101);
        vm.expectRevert(VerdictExecutor.BadParams.selector);
        exec.submitVerdict(v, sig);
    }

    function test_submit_revertsWhenFieldTampered() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, 60);
        v.clientPct = 100;
        vm.expectRevert(VerdictExecutor.BadSignature.selector);
        exec.submitVerdict(v, sig);
    }

    function test_submit_revertsForOtherDomain() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v,) = _verdict(id, 1, 60);
        // Signed for a different chain.
        vm.chainId(999);
        bytes memory sig = _sign(signerPk, SigUtils.verdictDigest(address(exec), id, 1, 60, REASONING, v.validUntil));
        vm.chainId(31337);
        vm.expectRevert(VerdictExecutor.BadSignature.selector);
        exec.submitVerdict(v, sig);
    }

    function test_submit_revertsOnMalformedSignature() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v,) = _verdict(id, 1, 60);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
        exec.submitVerdict(v, hex"010203");
    }

    function test_submit_revertsAfterRevoke() public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, 60);
        vm.prank(owner);
        exec.revokeSigner();
        vm.expectRevert(VerdictExecutor.NoSigner.selector);
        exec.submitVerdict(v, sig);
    }

    function testFuzz_submit_rejectsWrongSigner(uint256 wrongPk) public {
        wrongPk = bound(wrongPk, 1, SECP256K1_ORDER - 1);
        vm.assume(wrongPk != signerPk);
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v,) = _verdict(id, 1, 60);
        bytes memory sig = _sign(wrongPk, SigUtils.verdictDigest(address(exec), id, 1, 60, REASONING, v.validUntil));
        vm.expectRevert(VerdictExecutor.BadSignature.selector);
        exec.submitVerdict(v, sig);
    }

    function testFuzz_submit_expiry(uint48 validFor, uint48 elapsed) public {
        validFor = uint48(bound(validFor, 0, 30 days));
        elapsed = uint48(bound(elapsed, 0, 60 days));
        uint256 id = _createDisputed(AMOUNT);
        uint48 validUntil = uint48(block.timestamp) + validFor;
        VerdictExecutor.Verdict memory v = VerdictExecutor.Verdict(id, 1, 50, REASONING, validUntil);
        bytes memory sig = _sign(signerPk, SigUtils.verdictDigest(address(exec), id, 1, 50, REASONING, validUntil));

        vm.warp(block.timestamp + elapsed);
        if (elapsed > validFor) vm.expectRevert(VerdictExecutor.Expired.selector);
        exec.submitVerdict(v, sig);
    }

    function testFuzz_submit_anyPct(uint8 pct) public {
        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory sig) = _verdict(id, 1, pct);
        if (pct > 100) vm.expectRevert(VerdictExecutor.BadParams.selector);
        exec.submitVerdict(v, sig);
    }

    // =================================================================== signer rotation

    function test_rotation_delayEnforced() public {
        address next = makeAddr("next");
        vm.prank(owner);
        exec.proposeSigner(next);
        assertEq(exec.pendingSigner(), next);
        uint48 eta = exec.pendingSignerEta();
        assertEq(eta, block.timestamp + exec.SIGNER_DELAY());

        vm.warp(eta - 1);
        vm.expectRevert(VerdictExecutor.NotReady.selector);
        exec.applySigner();

        vm.warp(eta);
        vm.prank(stranger); // permissionless once eta passes
        exec.applySigner();
        assertEq(exec.signer(), next);
        assertEq(exec.pendingSigner(), address(0));
        assertEq(exec.pendingSignerEta(), 0);
    }

    function test_rotation_applyWithoutProposalReverts() public {
        vm.expectRevert(VerdictExecutor.NotReady.selector);
        exec.applySigner();
    }

    function test_rotation_revokeCancelsPending() public {
        vm.startPrank(owner);
        exec.proposeSigner(makeAddr("next"));
        exec.revokeSigner();
        vm.stopPrank();
        assertEq(exec.signer(), address(0));
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(VerdictExecutor.NotReady.selector);
        exec.applySigner();
    }

    function test_rotation_newSignerWorksOldDoesNot() public {
        (address next, uint256 nextPk) = makeAddrAndKey("next");
        vm.prank(owner);
        exec.proposeSigner(next);
        vm.warp(block.timestamp + exec.SIGNER_DELAY());
        exec.applySigner();

        uint256 id = _createDisputed(AMOUNT);
        (VerdictExecutor.Verdict memory v, bytes memory oldSig) = _verdict(id, 1, 60);
        vm.expectRevert(VerdictExecutor.BadSignature.selector);
        exec.submitVerdict(v, oldSig);

        bytes memory newSig = _sign(nextPk, SigUtils.verdictDigest(address(exec), id, 1, 60, REASONING, v.validUntil));
        exec.submitVerdict(v, newSig);
    }

    function test_rotation_proposeZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(VerdictExecutor.BadParams.selector);
        exec.proposeSigner(address(0));
    }

    function testFuzz_rotation_onlyOwner(address caller) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        exec.proposeSigner(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        exec.revokeSigner();
        vm.stopPrank();
    }

    function testFuzz_rotation_delay(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 30 days);
        address next = makeAddr("next");
        vm.prank(owner);
        exec.proposeSigner(next);
        vm.warp(block.timestamp + elapsed);
        if (elapsed < exec.SIGNER_DELAY()) {
            vm.expectRevert(VerdictExecutor.NotReady.selector);
            exec.applySigner();
        } else {
            exec.applySigner();
            assertEq(exec.signer(), next);
        }
    }

    function test_ownership_twoStep() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        exec.transferOwnership(newOwner);
        assertEq(exec.owner(), owner);
        vm.prank(newOwner);
        exec.acceptOwnership();
        assertEq(exec.owner(), newOwner);
    }
}
