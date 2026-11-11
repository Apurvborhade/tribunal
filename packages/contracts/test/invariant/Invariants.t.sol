// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EscrowVault} from "../../src/EscrowVault.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Handler} from "./Handler.sol";

contract InvariantsTest is BaseTest {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(vault, exec, court, usdc, signerPk);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = Handler.createAgreement.selector;
        selectors[1] = Handler.markDelivered.selector;
        selectors[2] = Handler.release.selector;
        selectors[3] = Handler.claimAfterReview.selector;
        selectors[4] = Handler.refundUndelivered.selector;
        selectors[5] = Handler.openDispute.selector;
        selectors[6] = Handler.ruleRoundOne.selector;
        selectors[7] = Handler.appeal.selector;
        selectors[8] = Handler.ruleRoundTwo.selector;
        selectors[9] = Handler.settleRuling.selector;
        selectors[10] = Handler.timeoutSplit.selector;
        selectors[11] = Handler.settleBond.selector;
        selectors[12] = Handler.withdrawClaimable.selector;
        selectors[13] = Handler.courtWithdraw.selector;
        selectors[14] = Handler.toggleBlacklist.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        // warp gets extra weight so time-gated paths are reachable.
        bytes4[] memory warpSel = new bytes4[](1);
        warpSel[0] = Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: warpSel}));
    }

    /// The vault always holds exactly what it owes: live escrows plus deferred payouts.
    function invariant_vaultSolvent() public view {
        assertEq(usdc.balanceOf(address(vault)), vault.totalEscrowed() + vault.totalClaimable());
    }

    /// totalEscrowed matches the sum of unresolved agreements and the deposit/settle ledger.
    function invariant_escrowAccounting() public view {
        uint256 sum;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            EscrowVault.Agreement memory a = vault.getAgreement(handler.ids(i));
            if (a.state != EscrowVault.State.Resolved) sum += a.amount;
        }
        assertEq(vault.totalEscrowed(), sum);
        assertEq(vault.totalEscrowed(), handler.ghost_deposited() - handler.ghost_settled());
        assertLe(vault.totalEscrowed(), vault.maxTotal());
    }

    /// Deferred payouts tracked per-user add up to totalClaimable.
    function invariant_claimableAccounting() public view {
        address[] memory actors = handler.actors();
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.claimable(actors[i]);
        }
        assertEq(vault.totalClaimable(), sum);
    }

    /// Once resolved, an agreement never leaves Resolved.
    function invariant_resolvedIsFinal() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            if (handler.everResolved(id)) assertEq(uint8(_state(id)), uint8(EscrowVault.State.Resolved));
        }
    }

    /// The court holds exactly the unsettled bonds plus what it owes in claimables.
    function invariant_courtSolvent() public view {
        uint256 owed;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            (address appellant, uint128 amt, bool settled) = court.bonds(handler.ids(i));
            if (appellant != address(0) && !settled) owed += amt;
        }
        address[] memory actors = handler.actors();
        for (uint256 i; i < actors.length; ++i) {
            owed += court.claimable(actors[i]);
        }
        owed += court.claimable(treasury);
        assertEq(usdc.balanceOf(address(court)), owed);
    }

    /// No tokens are created or lost: everything minted sits with an actor, the treasury, the vault or the court.
    function invariant_tokensConserved() public view {
        assertEq(usdc.totalSupply(), handler.ghost_minted());
        address[] memory actors = handler.actors();
        uint256 held = usdc.balanceOf(address(vault)) + usdc.balanceOf(address(court)) + usdc.balanceOf(treasury);
        for (uint256 i; i < actors.length; ++i) {
            held += usdc.balanceOf(actors[i]);
        }
        assertEq(held, usdc.totalSupply());
    }
}
