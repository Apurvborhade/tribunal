// script/Deploy.s.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {VerdictExecutor} from "../src/VerdictExecutor.sol";
import {AppealCourt} from "../src/AppealCourt.sol";
import {IEscrowVault} from "../src/interfaces/IEscrowVault.sol";

contract Deploy is Script {
    function run() external {
        address usdc = vm.envAddress("USDC");
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        address signer = vm.envAddress("VERDICT_SIGNER");

        vm.startBroadcast();

        address deployer = msg.sender;
        uint64 n = vm.getNonce(deployer);

        address predictedVault = vm.computeCreateAddress(deployer, n + 2);

        VerdictExecutor exec = new VerdictExecutor(address(IEscrowVault(predictedVault)), signer, owner);
        AppealCourt court = new AppealCourt(IERC20(usdc), IEscrowVault(predictedVault), treasury, owner);
        EscrowVault vault =
            new EscrowVault(IERC20(usdc), treasury, address(exec), address(court), 20, 5e6, 4000, owner);
        require(address(vault) == predictedVault, "address prediction failed");
        vm.stopBroadcast();
        console2.log("executor", address(exec));
        console2.log("court", address(court));
        console2.log("vault", address(vault));
        console2.log("block", block.number);
    }
}
