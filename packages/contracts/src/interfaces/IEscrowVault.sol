pragma solidity ^0.8.0;

interface IEscrowVault {
    enum State {
        None,
        Funded,
        Delivered,
        Disputed,
        Ruled,
        Appealed,
        Resolved
    }
    
    function recordRuling(uint256 id, uint8 round, uint8 clientPct, bytes32 reasoningHash) external;
    function markAppealed(uint256 id) external;
    function parties(uint256 id) external view returns (address client, address provider, uint128 amount);
    function rulingInfo(uint256 id) external view returns (State state, uint8 ruledRound, uint8 pct1, uint8 pct2);
}