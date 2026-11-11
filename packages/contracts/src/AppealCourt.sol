// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IEscrowVault} from "./interfaces/IEscrowVault.sol";

contract AppealCourt is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BOND_BPS = 1000; // 10% hard cap
    uint256 public constant MAX_MIN_BOND = 50e6; // 50 USDC hard cap (6 decimals)

    IERC20 public immutable usdc;
    IEscrowVault public immutable vault;
    address public treasury;
    uint16 public bondBps = 200; // 2%
    uint256 public minBond = 5e6; // 5 USDC

    struct Bond {
        address appellant;
        uint128 amount;
        bool settled;
    }
    mapping(uint256 => Bond) public bonds;
    mapping(address => uint256) public claimable;

    error NotParty();
    error AlreadyAppealed();
    error NoBond();
    error NotResolved();
    error AlreadySettled();
    error BadParams();
    error NothingToClaim();

    event Appealed(uint256 indexed id, address indexed appellant, uint256 bond);
    event BondSettled(uint256 indexed id, address indexed to, uint256 amount, bool refunded);
    event Withdrawn(address indexed who, uint256 amount);
    event ParamsChanged(uint16 bondBps, uint256 minBond);
    event TreasuryChanged(address treasury);

    constructor(IERC20 _usdc, IEscrowVault _vault, address _treasury, address _owner) Ownable(_owner) {
        if (_treasury == address(0)) revert BadParams();
        usdc = _usdc;
        vault = _vault;
        treasury = _treasury;
    }

    function bondFor(uint256 escrowAmount) public view returns (uint256) {
        uint256 pct = (escrowAmount * bondBps) / 10_000;
        return pct > minBond ? pct : minBond;
    }

    function appeal(uint256 id) external nonReentrant {
        (address client, address provider, uint128 amount) = vault.parties(id);
        if (msg.sender != client && msg.sender != provider) revert NotParty();
        if (bonds[id].appellant != address(0)) revert AlreadyAppealed();
        uint256 bond = bondFor(amount);

        bonds[id] = Bond({appellant: msg.sender, amount: uint128(bond), settled: false});
        usdc.safeTransferFrom(msg.sender, address(this), bond);
        vault.markAppealed(id); // reverts unless state == Ruled and the 48h window is open
        emit Appealed(id, msg.sender, bond);
    }

    function settleBond(uint256 id) external nonReentrant {
        Bond storage b = bonds[id];
        if (b.appellant == address(0)) revert NoBond();
        if (b.settled) revert AlreadySettled();

        (IEscrowVault.State st, uint8 ruledRound, uint8 pct1, uint8 pct2) = vault.rulingInfo(id);
        if (st != IEscrowVault.State.Resolved) revert NotResolved();

        b.settled = true;
        // ruledRound == 1 means the appeal timed out and round 1 stood: not the appellant's fault.
        bool refund = (ruledRound == 1) || (pct1 != pct2);
        address to = refund ? b.appellant : treasury;
        claimable[to] += b.amount;
        emit BondSettled(id, to, b.amount, refund);
    }

    function withdraw() external nonReentrant {
        uint256 amt = claimable[msg.sender];
        if (amt == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, amt);
        emit Withdrawn(msg.sender, amt);
    }

    function setParams(uint16 bps, uint256 minB) external onlyOwner {
        if (bps > MAX_BOND_BPS || minB > MAX_MIN_BOND) revert BadParams();
        bondBps = bps;
        minBond = minB;
        emit ParamsChanged(bps, minB);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert BadParams();
        treasury = t;
        emit TreasuryChanged(t);
    }
}
