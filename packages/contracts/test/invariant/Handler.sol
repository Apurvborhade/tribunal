// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EscrowVault} from "../../src/EscrowVault.sol";
import {VerdictExecutor} from "../../src/VerdictExecutor.sol";
import {AppealCourt} from "../../src/AppealCourt.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {SigUtils} from "../utils/SigUtils.sol";

/// @notice Drives random but *valid* actions against the system. Every action checks its own preconditions
///         and returns early when they don't hold, so with fail_on_revert = true any revert is a real bug.
contract Handler is Test {
    EscrowVault public immutable vault;
    VerdictExecutor public immutable exec;
    AppealCourt public immutable court;
    MockUSDC public immutable usdc;
    uint256 internal immutable signerPk;

    address[] internal clients;
    address[] internal providers;
    uint256[] internal providerPks;
    address[] internal actorList;

    uint256[] public ids;
    mapping(uint256 => bool) public everResolved;
    uint256 internal nonce;

    uint256 public ghost_minted;
    uint256 public ghost_deposited;
    uint256 public ghost_settled;
    mapping(bytes32 => uint256) public calls;

    modifier count(bytes32 name) {
        calls[name]++;
        _;
    }

    constructor(EscrowVault _vault, VerdictExecutor _exec, AppealCourt _court, MockUSDC _usdc, uint256 _signerPk) {
        vault = _vault;
        exec = _exec;
        court = _court;
        usdc = _usdc;
        signerPk = _signerPk;
        for (uint256 i; i < 3; ++i) {
            address c = makeAddr(string.concat("client", vm.toString(i)));
            (address p, uint256 pk) = makeAddrAndKey(string.concat("provider", vm.toString(i)));
            clients.push(c);
            providers.push(p);
            providerPks.push(pk);
            actorList.push(c);
            actorList.push(p);
        }
    }

    // ------------------------------------------------------------------ views for invariants

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function actors() external view returns (address[] memory) {
        return actorList;
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Starting at a random index, returns the first agreement in one of `states` (bitmask over State).
    ///      Picking among eligible agreements keeps deep paths (appeal, round 2, bonds) reachable.
    function _pick(uint256 seed, uint256 states)
        internal
        view
        returns (uint256 id, EscrowVault.Agreement memory a, bool ok)
    {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            id = ids[(seed % n + i) % n];
            a = vault.getAgreement(id);
            if (states & (1 << uint8(a.state)) != 0) return (id, a, true);
        }
    }

    function _bit(EscrowVault.State st) internal pure returns (uint256) {
        return 1 << uint8(st);
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _markSettled(uint256 id, uint128 amount) internal {
        everResolved[id] = true;
        ghost_settled += amount;
    }

    function _submit(uint256 id, uint8 round, uint8 pct) internal {
        uint48 validUntil = uint48(block.timestamp);
        bytes memory sig =
            _sign(signerPk, SigUtils.verdictDigest(address(exec), id, round, pct, bytes32(id), validUntil));
        exec.submitVerdict(VerdictExecutor.Verdict(id, round, pct, bytes32(id), validUntil), sig);
    }

    // ------------------------------------------------------------------ actions

    function createAgreement(uint256 cSeed, uint256 pSeed, uint128 amount, uint256 deadlineOffset)
        external
        count("create")
    {
        address c = clients[cSeed % clients.length];
        uint256 pi = pSeed % providers.length;
        if (usdc.blacklisted(c)) return;

        uint256 room = vault.maxTotal() - vault.totalEscrowed();
        uint256 cap = room < vault.maxEscrow() ? room : vault.maxEscrow();
        if (cap == 0) return;
        amount = uint128(bound(amount, 1, cap));
        uint48 deadline = uint48(block.timestamp + bound(deadlineOffset, 1, 60 days));
        uint256 n = nonce++;
        bytes memory sig = _sign(
            providerPks[pi],
            SigUtils.acceptDigest(address(vault), c, providers[pi], amount, deadline, keccak256("t"), n)
        );

        uint256 total = amount + (uint256(amount) * vault.feeBps()) / 10_000;
        usdc.mint(c, total);
        ghost_minted += total;
        vm.startPrank(c);
        usdc.approve(address(vault), total);
        uint256 id = vault.createAgreement(providers[pi], amount, deadline, keccak256("t"), n, sig);
        vm.stopPrank();

        ids.push(id);
        ghost_deposited += amount;
    }

    function markDelivered(uint256 seed) external count("markDelivered") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Funded));
        if (!ok || a.state != EscrowVault.State.Funded) return;
        vm.prank(a.provider);
        vault.markDelivered(id);
    }

    function release(uint256 seed) external count("release") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) =
            _pick(seed, _bit(EscrowVault.State.Funded) | _bit(EscrowVault.State.Delivered));
        if (!ok || (a.state != EscrowVault.State.Funded && a.state != EscrowVault.State.Delivered)) return;
        vm.prank(a.client);
        vault.release(id);
        _markSettled(id, a.amount);
    }

    function claimAfterReview(uint256 seed) external count("claimAfterReview") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Delivered));
        if (!ok || a.state != EscrowVault.State.Delivered) return;
        if (block.timestamp <= a.stateAt + vault.REVIEW_WINDOW()) return;
        vault.claimAfterReview(id);
        _markSettled(id, a.amount);
    }

    function refundUndelivered(uint256 seed) external count("refundUndelivered") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Funded));
        if (!ok || a.state != EscrowVault.State.Funded) return;
        if (block.timestamp <= a.deadline + vault.DEADLINE_GRACE()) return;
        vault.refundUndelivered(id);
        _markSettled(id, a.amount);
    }

    function openDispute(uint256 seed) external count("openDispute") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) =
            _pick(seed, _bit(EscrowVault.State.Funded) | _bit(EscrowVault.State.Delivered));
        if (!ok) return;
        bool can = (a.state == EscrowVault.State.Funded && block.timestamp > a.deadline)
            || (a.state == EscrowVault.State.Delivered && block.timestamp <= a.stateAt + vault.REVIEW_WINDOW());
        if (!can) return;
        vm.prank(a.client);
        vault.openDispute(id);
    }

    function ruleRoundOne(uint256 seed, uint8 pct) external count("ruleRoundOne") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Disputed));
        if (!ok || a.state != EscrowVault.State.Disputed) return;
        _submit(id, 1, uint8(bound(pct, 0, 100)));
    }

    function appeal(uint256 seed, bool byClient) external count("appeal") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Ruled));
        if (!ok || a.state != EscrowVault.State.Ruled) return;
        if (block.timestamp > a.stateAt + vault.APPEAL_WINDOW()) return;
        address who = byClient ? a.client : a.provider;
        if (usdc.blacklisted(who)) return;

        uint256 bond = court.bondFor(a.amount);
        usdc.mint(who, bond);
        ghost_minted += bond;
        vm.startPrank(who);
        usdc.approve(address(court), bond);
        court.appeal(id);
        vm.stopPrank();
        calls["appeal.ok"]++;
    }

    function ruleRoundTwo(uint256 seed, uint8 pct) external count("ruleRoundTwo") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Appealed));
        if (!ok || a.state != EscrowVault.State.Appealed) return;
        _submit(id, 2, uint8(bound(pct, 0, 100)));
        _markSettled(id, a.amount);
        calls["ruleRoundTwo.ok"]++;
    }

    function settleRuling(uint256 seed) external count("settleRuling") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Ruled));
        if (!ok || a.state != EscrowVault.State.Ruled) return;
        if (block.timestamp <= a.stateAt + vault.APPEAL_WINDOW()) return;
        vault.settleRuling(id);
        _markSettled(id, a.amount);
    }

    function timeoutSplit(uint256 seed) external count("timeoutSplit") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) =
            _pick(seed, _bit(EscrowVault.State.Disputed) | _bit(EscrowVault.State.Appealed));
        if (!ok || (a.state != EscrowVault.State.Disputed && a.state != EscrowVault.State.Appealed)) return;
        if (block.timestamp <= a.stateAt + vault.VERDICT_TIMEOUT()) return;
        vault.timeoutSplit(id);
        _markSettled(id, a.amount);
        calls["timeoutSplit.ok"]++;
    }

    function settleBond(uint256 seed) external count("settleBond") {
        (uint256 id, EscrowVault.Agreement memory a, bool ok) = _pick(seed, _bit(EscrowVault.State.Resolved));
        if (!ok || a.state != EscrowVault.State.Resolved) return;
        (address appellant,, bool settled) = court.bonds(id);
        if (appellant == address(0) || settled) return;
        court.settleBond(id);
        calls["settleBond.ok"]++;
    }

    function withdrawClaimable(uint256 seed) external count("withdrawClaimable") {
        address who = actorList[seed % actorList.length];
        if (vault.claimable(who) == 0 || usdc.blacklisted(who)) return;
        vm.prank(who);
        vault.withdrawClaimable();
        calls["withdrawClaimable.ok"]++;
    }

    function courtWithdraw(uint256 seed) external count("courtWithdraw") {
        address who = seed % 7 == 0 ? court.treasury() : actorList[seed % actorList.length];
        if (court.claimable(who) == 0 || usdc.blacklisted(who)) return;
        vm.prank(who);
        court.withdraw();
    }

    function toggleBlacklist(uint256 seed) external count("toggleBlacklist") {
        address who = actorList[seed % actorList.length];
        usdc.setBlacklisted(who, !usdc.blacklisted(who));
    }

    function warp(uint256 secs) external count("warp") {
        // Mostly short hops so the 48h appeal window is often still open; occasionally long ones for timeouts.
        uint256 maxHop = secs % 4 == 0 ? 20 days : 2 days;
        vm.warp(block.timestamp + bound(secs, 1, maxHop));
    }
}
