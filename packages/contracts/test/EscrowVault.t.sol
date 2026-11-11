// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {SigUtils} from "./utils/SigUtils.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";

contract EscrowVaultTest is BaseTest {
    event AgreementCreated(
        uint256 indexed id,
        address indexed client,
        address indexed provider,
        uint128 amount,
        uint48 deadline,
        bytes32 termsHash
    );
    event Settled(uint256 indexed id, uint256 toClient, uint256 toProvider, EscrowVault.Reason reason);
    event PayoutDeferred(address indexed to, uint256 amount);
    event EvidenceCommitted(uint256 indexed id, address indexed party, bytes32 hash);

    // =================================================================== constructor

    function test_constructor_setsImmutables() public view {
        assertEq(address(vault.token()), address(usdc));
        assertEq(vault.treasury(), treasury);
        assertEq(vault.executor(), address(exec));
        assertEq(vault.appealCourt(), address(court));
        assertEq(vault.feeBps(), FEE_BPS);
        assertEq(vault.maxEscrow(), MAX_ESCROW);
        assertEq(vault.maxTotal(), MAX_TOTAL);
        assertEq(vault.owner(), owner);
        assertEq(vault.nextId(), 1);
    }

    function test_constructor_typehashMatchesSpec() public view {
        assertEq(vault.ACCEPT_TYPEHASH(), SigUtils.ACCEPT_TYPEHASH);
    }

    function testFuzz_constructor_revertsWhenFeeAboveMax(uint16 fee) public {
        fee = uint16(bound(fee, vault.MAX_FEE_BPS() + 1, type(uint16).max));
        vm.expectRevert(EscrowVault.BadParams.selector);
        new EscrowVault(IERC20(address(usdc)), treasury, address(exec), address(court), fee, 1, 1, owner);
    }

    // =================================================================== createAgreement

    function test_create_fundsEscrowAndChargesFee() public {
        uint48 deadline = uint48(block.timestamp + 30 days);
        _fund(client, AMOUNT + _fee(AMOUNT));
        bytes memory sig = _acceptSig(providerPk, client, provider, AMOUNT, deadline, TERMS, 7);

        vm.expectEmit(address(vault));
        emit AgreementCreated(1, client, provider, AMOUNT, deadline, TERMS);
        vm.prank(client);
        uint256 id = vault.createAgreement(provider, AMOUNT, deadline, TERMS, 7, sig);

        assertEq(id, 1);
        assertEq(vault.nextId(), 2);
        assertEq(usdc.balanceOf(address(vault)), AMOUNT);
        assertEq(usdc.balanceOf(treasury), _fee(AMOUNT));
        assertEq(usdc.balanceOf(client), 0);
        assertEq(vault.totalEscrowed(), AMOUNT);
        assertTrue(vault.usedNonce(provider, 7));

        EscrowVault.Agreement memory a = vault.getAgreement(id);
        assertEq(a.client, client);
        assertEq(a.provider, provider);
        assertEq(a.amount, AMOUNT);
        assertEq(a.deadline, deadline);
        assertEq(uint8(a.state), uint8(EscrowVault.State.Funded));
        assertEq(a.stateAt, block.timestamp);
        assertEq(a.termsHash, TERMS);
    }

    function test_create_zeroFeeWhenAmountTiny() public {
        // 20 bps of 499 rounds down to 0: no second transferFrom to treasury.
        _create(499, uint48(block.timestamp + 1 days));
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(vault)), 499);
    }

    function test_create_revertsOnBadParams() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig = _acceptSig(providerPk, client, provider, AMOUNT, deadline, TERMS, 0);

        vm.startPrank(client);
        vm.expectRevert(EscrowVault.BadParams.selector);
        vault.createAgreement(address(0), AMOUNT, deadline, TERMS, 0, sig);
        vm.expectRevert(EscrowVault.BadParams.selector);
        vault.createAgreement(provider, 0, deadline, TERMS, 0, sig);
        vm.expectRevert(EscrowVault.BadParams.selector);
        vault.createAgreement(provider, AMOUNT, uint48(block.timestamp), TERMS, 0, sig);
        vm.expectRevert(EscrowVault.BadParams.selector);
        vault.createAgreement(provider, AMOUNT, deadline, bytes32(0), 0, sig);
        vm.stopPrank();
    }

    function test_create_revertsAboveMaxEscrow() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        vm.prank(client);
        vm.expectRevert(EscrowVault.CapExceeded.selector);
        vault.createAgreement(provider, MAX_ESCROW + 1, deadline, TERMS, 0, "");
    }

    function test_create_revertsAboveMaxTotal() public {
        for (uint256 i; i < MAX_TOTAL / MAX_ESCROW; ++i) {
            _create(MAX_ESCROW, uint48(block.timestamp + 1 days));
        }
        assertEq(vault.totalEscrowed(), MAX_TOTAL);
        vm.prank(client);
        vm.expectRevert(EscrowVault.CapExceeded.selector);
        vault.createAgreement(provider, 1, uint48(block.timestamp + 1 days), TERMS, 999, "");
    }

    function test_create_revertsOnNonceReplay() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig = _acceptSig(providerPk, client, provider, AMOUNT, deadline, TERMS, 42);
        _fund(client, 2 * (AMOUNT + _fee(AMOUNT)));
        vm.startPrank(client);
        vault.createAgreement(provider, AMOUNT, deadline, TERMS, 42, sig);
        vm.expectRevert(EscrowVault.BadParams.selector);
        vault.createAgreement(provider, AMOUNT, deadline, TERMS, 42, sig);
        vm.stopPrank();
    }

    function test_create_revertsWhenSignatureForDifferentClient() public {
        // Provider signed for `client`; a front-runner can't reuse it.
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig = _acceptSig(providerPk, client, provider, AMOUNT, deadline, TERMS, 0);
        _fund(stranger, AMOUNT + _fee(AMOUNT));
        vm.prank(stranger);
        vm.expectRevert(EscrowVault.BadSignature.selector);
        vault.createAgreement(provider, AMOUNT, deadline, TERMS, 0, sig);
    }

    function test_create_revertsWhenTermsTampered() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig = _acceptSig(providerPk, client, provider, AMOUNT, deadline, TERMS, 0);
        _fund(client, 10 * AMOUNT);
        vm.startPrank(client);
        vm.expectRevert(EscrowVault.BadSignature.selector);
        vault.createAgreement(provider, AMOUNT - 1, deadline, TERMS, 0, sig);
        vm.expectRevert(EscrowVault.BadSignature.selector);
        vault.createAgreement(provider, AMOUNT, deadline + 1, TERMS, 0, sig);
        vm.expectRevert(EscrowVault.BadSignature.selector);
        vault.createAgreement(provider, AMOUNT, deadline, keccak256("other"), 0, sig);
        vm.expectRevert(EscrowVault.BadSignature.selector);
        vault.createAgreement(provider, AMOUNT, deadline, TERMS, 1, sig);
        vm.stopPrank();
    }

    function test_create_acceptsERC1271Provider() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(provider);
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig = _acceptSig(providerPk, client, address(wallet), AMOUNT, deadline, TERMS, 0);
        _fund(client, AMOUNT + _fee(AMOUNT));
        vm.prank(client);
        uint256 id = vault.createAgreement(address(wallet), AMOUNT, deadline, TERMS, 0, sig);
        assertEq(vault.getAgreement(id).provider, address(wallet));
    }

    function test_create_revertsWithoutAllowance() public {
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig = _acceptSig(providerPk, client, provider, AMOUNT, deadline, TERMS, 0);
        usdc.mint(client, AMOUNT + _fee(AMOUNT));
        vm.prank(client);
        vm.expectRevert();
        vault.createAgreement(provider, AMOUNT, deadline, TERMS, 0, sig);
    }

    function testFuzz_create(uint128 amount, uint48 deadlineOffset, bytes32 terms, uint256 nonce) public {
        amount = uint128(bound(amount, 1, MAX_ESCROW));
        deadlineOffset = uint48(bound(deadlineOffset, 1, 10 * 365 days));
        vm.assume(terms != bytes32(0));
        uint48 deadline = uint48(block.timestamp) + deadlineOffset;

        bytes memory sig = _acceptSig(providerPk, client, provider, amount, deadline, terms, nonce);
        _fund(client, amount + _fee(amount));
        vm.prank(client);
        uint256 id = vault.createAgreement(provider, amount, deadline, terms, nonce, sig);

        assertEq(usdc.balanceOf(address(vault)), amount);
        assertEq(usdc.balanceOf(treasury), _fee(amount));
        assertEq(vault.totalEscrowed(), amount);
        assertTrue(vault.usedNonce(provider, nonce));
        assertEq(vault.getAgreement(id).amount, amount);
    }

    function testFuzz_create_rejectsSignatureFromWrongKey(uint256 wrongPk) public {
        wrongPk = bound(wrongPk, 1, SECP256K1_ORDER - 1);
        vm.assume(wrongPk != providerPk);
        uint48 deadline = uint48(block.timestamp + 1 days);
        bytes memory sig = _acceptSig(wrongPk, client, provider, AMOUNT, deadline, TERMS, 0);
        _fund(client, AMOUNT + _fee(AMOUNT));
        vm.prank(client);
        vm.expectRevert(EscrowVault.BadSignature.selector);
        vault.createAgreement(provider, AMOUNT, deadline, TERMS, 0, sig);
    }

    function testFuzz_create_capEnforced(uint128 amount) public {
        amount = uint128(bound(amount, uint256(MAX_ESCROW) + 1, type(uint128).max));
        vm.prank(client);
        vm.expectRevert(EscrowVault.CapExceeded.selector);
        vault.createAgreement(provider, amount, uint48(block.timestamp + 1), TERMS, 0, "");
    }

    // =================================================================== markDelivered

    function test_markDelivered() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 5 days);
        vm.prank(provider);
        vault.markDelivered(id);
        EscrowVault.Agreement memory a = vault.getAgreement(id);
        assertEq(uint8(a.state), uint8(EscrowVault.State.Delivered));
        assertEq(a.stateAt, block.timestamp);
    }

    function test_markDelivered_onlyProvider() public {
        uint256 id = _create();
        vm.prank(client);
        vm.expectRevert(EscrowVault.NotProvider.selector);
        vault.markDelivered(id);
        vm.prank(stranger);
        vm.expectRevert(EscrowVault.NotProvider.selector);
        vault.markDelivered(id);
    }

    function test_markDelivered_revertsWhenNotFunded() public {
        uint256 id = _create();
        vm.startPrank(provider);
        vault.markDelivered(id);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Delivered));
        vault.markDelivered(id);
        vm.stopPrank();
    }

    // =================================================================== release

    function test_release_fromFundedPaysProvider() public {
        uint256 id = _create();
        vm.expectEmit(address(vault));
        emit Settled(id, 0, AMOUNT, EscrowVault.Reason.Released);
        vm.prank(client);
        vault.release(id);
        assertEq(usdc.balanceOf(provider), AMOUNT);
        assertEq(usdc.balanceOf(client), 0);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalEscrowed(), 0);
        assertEq(uint8(_state(id)), uint8(EscrowVault.State.Resolved));
    }

    function test_release_fromDeliveredPaysProvider() public {
        uint256 id = _create();
        vm.prank(provider);
        vault.markDelivered(id);
        vm.prank(client);
        vault.release(id);
        assertEq(usdc.balanceOf(provider), AMOUNT);
    }

    function test_release_onlyClient() public {
        uint256 id = _create();
        vm.prank(provider);
        vm.expectRevert(EscrowVault.NotClient.selector);
        vault.release(id);
    }

    function test_release_revertsTwice() public {
        uint256 id = _create();
        vm.startPrank(client);
        vault.release(id);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Resolved));
        vault.release(id);
        vm.stopPrank();
    }

    function test_release_revertsWhenDisputed() public {
        uint256 id = _createDisputed(AMOUNT);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Disputed));
        vault.release(id);
    }

    // =================================================================== claimAfterReview

    function test_claimAfterReview_paysProviderAfterWindow() public {
        uint256 id = _create();
        vm.prank(provider);
        vault.markDelivered(id);

        uint256 deliveredAt = vm.getBlockTimestamp();
        vm.warp(deliveredAt + vault.REVIEW_WINDOW());
        vm.expectRevert(EscrowVault.TooEarly.selector);
        vault.claimAfterReview(id);

        vm.warp(deliveredAt + vault.REVIEW_WINDOW() + 1);
        vm.prank(stranger); // permissionless
        vault.claimAfterReview(id);
        assertEq(usdc.balanceOf(provider), AMOUNT);
    }

    function test_claimAfterReview_revertsWhenFunded() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Funded));
        vault.claimAfterReview(id);
    }

    function testFuzz_claimAfterReview_timing(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 30 days);
        uint256 id = _create();
        vm.prank(provider);
        vault.markDelivered(id);
        vm.warp(block.timestamp + elapsed);
        if (elapsed <= vault.REVIEW_WINDOW()) {
            vm.expectRevert(EscrowVault.TooEarly.selector);
            vault.claimAfterReview(id);
        } else {
            vault.claimAfterReview(id);
            assertEq(usdc.balanceOf(provider), AMOUNT);
        }
    }

    // =================================================================== refundUndelivered

    function test_refundUndelivered_refundsClientAfterGrace() public {
        uint48 deadline = uint48(block.timestamp + 10 days);
        uint256 id = _create(AMOUNT, deadline);

        vm.warp(deadline + vault.DEADLINE_GRACE());
        vm.expectRevert(EscrowVault.TooEarly.selector);
        vault.refundUndelivered(id);

        vm.warp(deadline + vault.DEADLINE_GRACE() + 1);
        vm.expectEmit(address(vault));
        emit Settled(id, AMOUNT, 0, EscrowVault.Reason.Undelivered);
        vm.prank(stranger);
        vault.refundUndelivered(id);
        assertEq(usdc.balanceOf(client), AMOUNT);
        assertEq(usdc.balanceOf(provider), 0);
    }

    function test_refundUndelivered_revertsOnceDelivered() public {
        uint48 deadline = uint48(block.timestamp + 10 days);
        uint256 id = _create(AMOUNT, deadline);
        vm.prank(provider);
        vault.markDelivered(id);
        vm.warp(deadline + 30 days);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Delivered));
        vault.refundUndelivered(id);
    }

    // =================================================================== openDispute

    function test_openDispute_fromFundedOnlyAfterDeadline() public {
        uint48 deadline = uint48(block.timestamp + 10 days);
        uint256 id = _create(AMOUNT, deadline);

        vm.warp(deadline);
        vm.prank(client);
        vm.expectRevert(EscrowVault.TooEarly.selector);
        vault.openDispute(id);

        vm.warp(deadline + 1);
        vm.prank(client);
        vault.openDispute(id);
        assertEq(uint8(_state(id)), uint8(EscrowVault.State.Disputed));
    }

    function test_openDispute_fromDeliveredOnlyWithinReview() public {
        uint256 id = _create();
        vm.prank(provider);
        vault.markDelivered(id);
        uint256 t = vm.getBlockTimestamp();

        vm.warp(t + vault.REVIEW_WINDOW() + 1);
        vm.prank(client);
        vm.expectRevert(EscrowVault.TooLate.selector);
        vault.openDispute(id);

        vm.warp(t + vault.REVIEW_WINDOW());
        vm.prank(client);
        vault.openDispute(id);
        assertEq(uint8(_state(id)), uint8(EscrowVault.State.Disputed));
    }

    function test_openDispute_onlyClient() public {
        uint256 id = _create();
        vm.prank(provider);
        vault.markDelivered(id);
        vm.prank(provider);
        vm.expectRevert(EscrowVault.NotClient.selector);
        vault.openDispute(id);
    }

    function test_openDispute_revertsWhenAlreadyDisputed() public {
        uint256 id = _createDisputed(AMOUNT);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Disputed));
        vault.openDispute(id);
    }

    function testFuzz_openDispute_deliveredTiming(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 30 days);
        uint256 id = _create();
        vm.prank(provider);
        vault.markDelivered(id);
        vm.warp(block.timestamp + elapsed);
        bool late = elapsed > vault.REVIEW_WINDOW();
        vm.prank(client);
        if (late) vm.expectRevert(EscrowVault.TooLate.selector);
        vault.openDispute(id);
    }

    // =================================================================== commitEvidence

    function test_commitEvidence_bothParties() public {
        uint256 id = _createDisputed(AMOUNT);
        vm.expectEmit(address(vault));
        emit EvidenceCommitted(id, client, bytes32(uint256(1)));
        vm.prank(client);
        vault.commitEvidence(id, bytes32(uint256(1)));

        vm.expectEmit(address(vault));
        emit EvidenceCommitted(id, provider, bytes32(uint256(2)));
        vm.prank(provider);
        vault.commitEvidence(id, bytes32(uint256(2)));
    }

    function test_commitEvidence_reverts() public {
        uint256 id = _create();
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Funded));
        vault.commitEvidence(id, bytes32(0));

        vm.prank(stranger);
        vm.expectRevert(EscrowVault.NotParty.selector);
        vault.commitEvidence(id, bytes32(0));
    }

    // =================================================================== recordRuling / settleRuling

    function test_recordRuling_onlyExecutor() public {
        uint256 id = _createDisputed(AMOUNT);
        vm.expectRevert(EscrowVault.NotExecutor.selector);
        vault.recordRuling(id, 1, 50, REASONING);
    }

    function test_recordRuling_revertsOnBadPctOrRound() public {
        uint256 id = _createDisputed(AMOUNT);
        vm.startPrank(address(exec));
        vm.expectRevert(EscrowVault.BadPct.selector);
        vault.recordRuling(id, 1, 101, REASONING);
        vm.expectRevert(EscrowVault.BadRound.selector);
        vault.recordRuling(id, 2, 50, REASONING); // round 2 needs Appealed
        vm.expectRevert(EscrowVault.BadRound.selector);
        vault.recordRuling(id, 0, 50, REASONING);
        vm.stopPrank();
    }

    function test_ruling_settlesAfterAppealWindow() public {
        uint256 id = _createDisputed(AMOUNT);
        _rule(id, 1, 30);

        (EscrowVault.State st, uint8 round, uint8 pct1,) = vault.rulingInfo(id);
        assertEq(uint8(st), uint8(EscrowVault.State.Ruled));
        assertEq(round, 1);
        assertEq(pct1, 30);

        uint256 ruledAt = vm.getBlockTimestamp();
        vm.warp(ruledAt + vault.APPEAL_WINDOW());
        vm.expectRevert(EscrowVault.TooEarly.selector);
        vault.settleRuling(id);

        vm.warp(ruledAt + vault.APPEAL_WINDOW() + 1);
        vault.settleRuling(id);
        assertEq(usdc.balanceOf(client), (AMOUNT * 30) / 100);
        assertEq(usdc.balanceOf(provider), AMOUNT - (AMOUNT * 30) / 100);
    }

    function test_settleRuling_revertsWhenNotRuled() public {
        uint256 id = _createDisputed(AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Disputed));
        vault.settleRuling(id);
    }

    function testFuzz_ruling_splitConservesFunds(uint128 amount, uint8 pct) public {
        amount = uint128(bound(amount, 1, MAX_ESCROW));
        pct = uint8(bound(pct, 0, 100));
        uint256 id = _createDisputed(amount);
        _rule(id, 1, pct);
        vm.warp(block.timestamp + vault.APPEAL_WINDOW() + 1);
        vault.settleRuling(id);

        uint256 toClient = (uint256(amount) * pct) / 100;
        assertEq(usdc.balanceOf(client), toClient);
        assertEq(usdc.balanceOf(provider), amount - toClient);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalEscrowed(), 0);
    }

    function testFuzz_recordRuling_onlyExecutor(address caller) public {
        vm.assume(caller != address(exec));
        uint256 id = _createDisputed(AMOUNT);
        vm.prank(caller);
        vm.expectRevert(EscrowVault.NotExecutor.selector);
        vault.recordRuling(id, 1, 50, REASONING);
    }

    // =================================================================== appeals

    function test_markAppealed_onlyCourt() public {
        uint256 id = _createDisputed(AMOUNT);
        _rule(id, 1, 30);
        vm.prank(client);
        vm.expectRevert(EscrowVault.NotAppealCourt.selector);
        vault.markAppealed(id);
    }

    function test_appeal_roundTwoSettlesWithNewPct() public {
        uint256 id = _createDisputed(AMOUNT);
        _rule(id, 1, 30);
        _appeal(id, client);
        assertEq(uint8(_state(id)), uint8(EscrowVault.State.Appealed));

        _rule(id, 2, 80);
        (EscrowVault.State st, uint8 round, uint8 pct1, uint8 pct2) = vault.rulingInfo(id);
        assertEq(uint8(st), uint8(EscrowVault.State.Resolved));
        assertEq(round, 2);
        assertEq(pct1, 30);
        assertEq(pct2, 80);
        assertEq(usdc.balanceOf(client), (AMOUNT * 80) / 100);
        assertEq(usdc.balanceOf(provider), AMOUNT - (AMOUNT * 80) / 100);
    }

    // =================================================================== timeoutSplit

    function test_timeoutSplit_disputedSplitsEvenly() public {
        uint256 id = _createDisputed(AMOUNT);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + vault.VERDICT_TIMEOUT());
        vm.expectRevert(EscrowVault.TooEarly.selector);
        vault.timeoutSplit(id);

        vm.warp(t + vault.VERDICT_TIMEOUT() + 1);
        vault.timeoutSplit(id);
        assertEq(usdc.balanceOf(client), AMOUNT / 2);
        assertEq(usdc.balanceOf(provider), AMOUNT - AMOUNT / 2);
    }

    function test_timeoutSplit_appealedFallsBackToRoundOne() public {
        uint256 id = _createDisputed(AMOUNT);
        _rule(id, 1, 25);
        _appeal(id, provider);
        vm.warp(block.timestamp + vault.VERDICT_TIMEOUT() + 1);
        vault.timeoutSplit(id);
        assertEq(usdc.balanceOf(client), (AMOUNT * 25) / 100);
        assertEq(usdc.balanceOf(provider), AMOUNT - (AMOUNT * 25) / 100);
    }

    function test_timeoutSplit_revertsWhenRuled() public {
        uint256 id = _createDisputed(AMOUNT);
        _rule(id, 1, 25);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Ruled));
        vault.timeoutSplit(id);
    }

    // =================================================================== deferred payouts

    function test_blacklistedRecipient_payoutDeferredThenWithdrawn() public {
        uint256 id = _create();
        usdc.setBlacklisted(provider, true);

        vm.expectEmit(address(vault));
        emit PayoutDeferred(provider, AMOUNT);
        vm.prank(client);
        vault.release(id);

        assertEq(vault.claimable(provider), AMOUNT);
        assertEq(vault.totalClaimable(), AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), AMOUNT);

        vm.prank(provider);
        vm.expectRevert(); // still blacklisted
        vault.withdrawClaimable();

        usdc.setBlacklisted(provider, false);
        vm.prank(provider);
        vault.withdrawClaimable();
        assertEq(usdc.balanceOf(provider), AMOUNT);
        assertEq(vault.claimable(provider), 0);
        assertEq(vault.totalClaimable(), 0);
    }

    function test_blacklistedOneSide_otherSideStillPaid() public {
        uint256 id = _createDisputed(AMOUNT);
        _rule(id, 1, 40);
        usdc.setBlacklisted(client, true);
        vm.warp(block.timestamp + vault.APPEAL_WINDOW() + 1);
        vault.settleRuling(id);
        assertEq(vault.claimable(client), (AMOUNT * 40) / 100);
        assertEq(usdc.balanceOf(provider), AMOUNT - (AMOUNT * 40) / 100);
    }

    function test_withdrawClaimable_revertsWhenNothing() public {
        vm.expectRevert(EscrowVault.NothingToClaim.selector);
        vault.withdrawClaimable();
    }

    // =================================================================== views

    function test_views() public {
        uint256 id = _create();
        (address c, address p, uint128 amt) = vault.parties(id);
        assertEq(c, client);
        assertEq(p, provider);
        assertEq(amt, AMOUNT);

        (EscrowVault.State st,,,) = vault.rulingInfo(id);
        assertEq(uint8(st), uint8(EscrowVault.State.Funded));

        (address c0,,) = vault.parties(999);
        assertEq(c0, address(0));
    }

    function test_unknownId_cannotBeActedOn() public {
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.None));
        vault.claimAfterReview(999);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.None));
        vault.settleRuling(999);
        vm.expectRevert(EscrowVault.NotClient.selector);
        vault.release(999);
    }
}
