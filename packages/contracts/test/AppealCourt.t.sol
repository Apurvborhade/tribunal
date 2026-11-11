// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";
import {BaseTest} from "./utils/BaseTest.sol";

contract AppealCourtTest is BaseTest {
    event Appealed(uint256 indexed id, address indexed appellant, uint256 bond);
    event BondSettled(uint256 indexed id, address indexed to, uint256 amount, bool refunded);

    function _ruled(uint8 pct) internal returns (uint256 id) {
        id = _createDisputed(AMOUNT);
        _rule(id, 1, pct);
    }

    // =================================================================== config

    function test_constructor() public view {
        assertEq(address(court.usdc()), address(usdc));
        assertEq(address(court.vault()), address(vault));
        assertEq(court.treasury(), treasury);
        assertEq(court.owner(), owner);
        assertEq(court.bondBps(), 200);
        assertEq(court.minBond(), 5e6);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(AppealCourt.BadParams.selector);
        new AppealCourt(IERC20(address(usdc)), IEscrowVault(address(vault)), address(0), owner);
    }

    function test_bondFor() public view {
        assertEq(court.bondFor(0), 5e6); // floor
        assertEq(court.bondFor(100e6), 5e6); // 2% = 2 USDC < floor
        assertEq(court.bondFor(1_000e6), 20e6); // 2%
    }

    function testFuzz_bondFor(uint128 amount, uint16 bps, uint256 minB) public {
        bps = uint16(bound(bps, 0, court.MAX_BOND_BPS()));
        minB = bound(minB, 0, court.MAX_MIN_BOND());
        vm.prank(owner);
        court.setParams(bps, minB);

        uint256 bond = court.bondFor(amount);
        uint256 pct = (uint256(amount) * bps) / 10_000;
        assertEq(bond, pct > minB ? pct : minB);
        assertLe(bond, uint256(amount) / 10 > 50e6 ? uint256(amount) / 10 : 50e6); // never above hard caps
    }

    function testFuzz_setParams_capsEnforced(uint16 bps, uint256 minB) public {
        bool ok = bps <= court.MAX_BOND_BPS() && minB <= court.MAX_MIN_BOND();
        vm.prank(owner);
        if (!ok) vm.expectRevert(AppealCourt.BadParams.selector);
        court.setParams(bps, minB);
        if (ok) {
            assertEq(court.bondBps(), bps);
            assertEq(court.minBond(), minB);
        }
    }

    function testFuzz_adminOnlyOwner(address caller) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        court.setParams(100, 1e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        court.setTreasury(caller);
        vm.stopPrank();
    }

    function test_setTreasury() public {
        address t = makeAddr("newTreasury");
        vm.prank(owner);
        court.setTreasury(t);
        assertEq(court.treasury(), t);

        vm.prank(owner);
        vm.expectRevert(AppealCourt.BadParams.selector);
        court.setTreasury(address(0));
    }

    // =================================================================== appeal

    function test_appeal_takesBondAndMarksVault() public {
        uint256 id = _ruled(30);
        uint256 bond = court.bondFor(AMOUNT);
        usdc.mint(client, bond);
        vm.startPrank(client);
        usdc.approve(address(court), bond);
        vm.expectEmit(address(court));
        emit Appealed(id, client, bond);
        court.appeal(id);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(court)), bond);
        assertEq(uint8(_state(id)), uint8(EscrowVault.State.Appealed));
        (address appellant, uint128 amt, bool settled) = court.bonds(id);
        assertEq(appellant, client);
        assertEq(amt, bond);
        assertFalse(settled);
    }

    function test_appeal_onlyParty() public {
        uint256 id = _ruled(30);
        vm.prank(stranger);
        vm.expectRevert(AppealCourt.NotParty.selector);
        court.appeal(id);
    }

    function test_appeal_onlyOnce() public {
        uint256 id = _ruled(30);
        _appeal(id, client);
        uint256 bond = court.bondFor(AMOUNT);
        usdc.mint(provider, bond);
        vm.startPrank(provider);
        usdc.approve(address(court), bond);
        vm.expectRevert(AppealCourt.AlreadyAppealed.selector);
        court.appeal(id);
        vm.stopPrank();
    }

    function test_appeal_revertsBeforeRuling() public {
        uint256 id = _createDisputed(AMOUNT);
        uint256 bond = court.bondFor(AMOUNT);
        usdc.mint(client, bond);
        vm.startPrank(client);
        usdc.approve(address(court), bond);
        vm.expectRevert(abi.encodeWithSelector(EscrowVault.BadState.selector, EscrowVault.State.Disputed));
        court.appeal(id);
        vm.stopPrank();
        assertEq(usdc.balanceOf(client), bond); // bond pull rolled back
    }

    function test_appeal_revertsAfterWindow() public {
        uint256 id = _ruled(30);
        vm.warp(block.timestamp + vault.APPEAL_WINDOW() + 1);
        uint256 bond = court.bondFor(AMOUNT);
        usdc.mint(client, bond);
        vm.startPrank(client);
        usdc.approve(address(court), bond);
        vm.expectRevert(EscrowVault.TooLate.selector);
        court.appeal(id);
        vm.stopPrank();
    }

    function test_appeal_revertsWithoutBondFunds() public {
        uint256 id = _ruled(30);
        vm.prank(client);
        vm.expectRevert();
        court.appeal(id);
    }

    // =================================================================== settleBond

    function test_settleBond_refundedWhenRulingChanges() public {
        uint256 id = _ruled(30);
        uint256 bond = _appeal(id, client);
        _rule(id, 2, 70);

        vm.expectEmit(address(court));
        emit BondSettled(id, client, bond, true);
        court.settleBond(id);
        assertEq(court.claimable(client), bond);

        vm.prank(client);
        court.withdraw();
        assertEq(usdc.balanceOf(client), bond + (AMOUNT * 70) / 100);
        assertEq(usdc.balanceOf(address(court)), 0);
    }

    function test_settleBond_forfeitedWhenRulingUpheld() public {
        uint256 id = _ruled(30);
        uint256 bond = _appeal(id, provider);
        _rule(id, 2, 30);

        court.settleBond(id);
        assertEq(court.claimable(treasury), bond);
        assertEq(court.claimable(provider), 0);
        vm.prank(treasury);
        court.withdraw();
        assertEq(usdc.balanceOf(treasury), _fee(AMOUNT) + bond);
    }

    function test_settleBond_refundedWhenAppealTimesOut() public {
        uint256 id = _ruled(30);
        uint256 bond = _appeal(id, client);
        vm.warp(block.timestamp + vault.VERDICT_TIMEOUT() + 1);
        vault.timeoutSplit(id);
        court.settleBond(id);
        assertEq(court.claimable(client), bond);
    }

    function test_settleBond_reverts() public {
        uint256 id = _ruled(30);
        vm.expectRevert(AppealCourt.NoBond.selector);
        court.settleBond(id);

        _appeal(id, client);
        vm.expectRevert(AppealCourt.NotResolved.selector);
        court.settleBond(id);

        _rule(id, 2, 30);
        court.settleBond(id);
        vm.expectRevert(AppealCourt.AlreadySettled.selector);
        court.settleBond(id);
    }

    function test_withdraw_revertsWhenNothing() public {
        vm.expectRevert(AppealCourt.NothingToClaim.selector);
        court.withdraw();
    }

    function testFuzz_settleBond_outcome(uint8 pct1, uint8 pct2, bool clientAppeals) public {
        pct1 = uint8(bound(pct1, 0, 100));
        pct2 = uint8(bound(pct2, 0, 100));
        address appellant = clientAppeals ? client : provider;

        uint256 id = _ruled(pct1);
        uint256 bond = _appeal(id, appellant);
        _rule(id, 2, pct2);
        court.settleBond(id);

        address expected = pct1 != pct2 ? appellant : treasury;
        assertEq(court.claimable(expected), bond);
        assertEq(usdc.balanceOf(address(court)), bond);
    }

    function testFuzz_appeal_bondMatchesAmount(uint128 amount) public {
        amount = uint128(bound(amount, 1, MAX_ESCROW));
        uint256 id = _createDisputed(amount);
        _rule(id, 1, 50);
        uint256 bond = _appeal(id, client);
        assertEq(bond, court.bondFor(amount));
        assertEq(usdc.balanceOf(address(court)), bond);
    }
}
