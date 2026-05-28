// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RoleManager} from "../src/l1/RoleManager.sol";
import {DefaultPassHook} from "../src/l1/DefaultPassHook.sol";
import {KYBGateway} from "../src/l1/KYBGateway.sol";
import {IssuerRegistry} from "../src/l1/IssuerRegistry.sol";
import {ComplianceRegistry} from "../src/l1/ComplianceRegistry.sol";
import {ParameterArchive} from "../src/l2/ParameterArchive.sol";
import {CollateralRegistry} from "../src/l2/CollateralRegistry.sol";
import {DealRegistry} from "../src/l3/DealRegistry.sol";
import {EscrowVault} from "../src/l3/EscrowVault.sol";
import {LendingEngine} from "../src/l3/LendingEngine.sol";
import {LiquidationHandler} from "../src/l4/LiquidationHandler.sol";
import {SettlementRouter} from "../src/l4/SettlementRouter.sol";
import {PortfolioLens} from "../src/l5/PortfolioLens.sol";

/// @notice Reference deployment script.
///         Order mirrors architecture v3 §24 (deployment order). Run with:
///         forge script script/Deploy.s.sol --broadcast --rpc-url $RPC
contract Deploy is Script {
    function run() external {
        address bootstrap = msg.sender;
        address governor = vm.envOr("GOVERNOR", bootstrap);
        address attestor = vm.envOr("ATTESTOR", bootstrap);
        address aminaTreasury = vm.envOr("AMINA_TREASURY", bootstrap);

        vm.startBroadcast();

        // 1. RoleManager (immutable)
        RoleManager roleManager = new RoleManager(bootstrap);

        // 2. DefaultPassHook
        DefaultPassHook hook = new DefaultPassHook();

        // 3-5. UUPS L1 contracts
        KYBGateway kybImpl = new KYBGateway();
        KYBGateway kyb = KYBGateway(
            address(new ERC1967Proxy(address(kybImpl), abi.encodeCall(KYBGateway.initialize, (address(roleManager)))))
        );

        IssuerRegistry irImpl = new IssuerRegistry();
        IssuerRegistry issuers = IssuerRegistry(
            address(new ERC1967Proxy(address(irImpl), abi.encodeCall(IssuerRegistry.initialize, (address(roleManager)))))
        );

        ComplianceRegistry crImpl = new ComplianceRegistry();
        ComplianceRegistry compliance = ComplianceRegistry(
            address(
                new ERC1967Proxy(
                    address(crImpl),
                    abi.encodeCall(ComplianceRegistry.initialize, (address(roleManager), address(hook)))
                )
            )
        );

        // 6-7. CollateralRegistry + ParameterArchive (with predicted addr).
        CollateralRegistry collImpl = new CollateralRegistry();
        uint256 nonce = vm.getNonce(msg.sender);
        address predictedColl = vm.computeCreateAddress(msg.sender, nonce + 1);
        ParameterArchive archive = new ParameterArchive(predictedColl);
        CollateralRegistry collateralRegistry = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    address(collImpl),
                    abi.encodeCall(CollateralRegistry.initialize, (address(roleManager), address(archive)))
                )
            )
        );
        require(address(collateralRegistry) == predictedColl, "coll addr");

        // 8-13. L3/L4/L5 chain.
        nonce = vm.getNonce(msg.sender);
        address predictedEngine = vm.computeCreateAddress(msg.sender, nonce + 4);
        DealRegistry dealRegistry = new DealRegistry(predictedEngine);
        EscrowVault vault = new EscrowVault(governor);
        SettlementRouter router = new SettlementRouter(bootstrap);

        LendingEngine engineImpl = new LendingEngine();
        nonce = vm.getNonce(msg.sender);
        address predictedHandler = vm.computeCreateAddress(msg.sender, nonce + 2);
        LendingEngine engine = LendingEngine(
            address(
                new ERC1967Proxy(
                    address(engineImpl),
                    abi.encodeCall(
                        LendingEngine.initialize,
                        (
                            LendingEngine.InitParams({
                                authority: address(roleManager),
                                kyb: address(kyb),
                                issuers: address(issuers),
                                compliance: address(compliance),
                                collateral: address(collateralRegistry),
                                archive: address(archive),
                                deals: address(dealRegistry),
                                vault: address(vault),
                                router: address(router),
                                handler: predictedHandler
                            })
                        )
                    )
                )
            )
        );
        require(address(engine) == predictedEngine, "engine addr");

        LiquidationHandler handlerImpl = new LiquidationHandler();
        LiquidationHandler handler = LiquidationHandler(
            address(
                new ERC1967Proxy(
                    address(handlerImpl),
                    abi.encodeCall(
                        LiquidationHandler.initialize,
                        (
                            LiquidationHandler.InitParams({
                                authority: address(roleManager),
                                engine: address(engine),
                                router: address(router),
                                vault: address(vault),
                                deals: address(dealRegistry),
                                archive: address(archive),
                                compliance: address(compliance),
                                attestor: attestor,
                                aminaTreasury: aminaTreasury,
                                attestationStaleSecs: 10 minutes
                            })
                        )
                    )
                )
            )
        );

        vault.bindEngine(address(engine)); // requires sender == governor
        router.bind(address(engine), address(handler));
        issuers.bindEngine(address(engine));

        PortfolioLens lens = new PortfolioLens(address(engine), address(dealRegistry), address(vault));

        vm.stopBroadcast();

        console2.log("RoleManager        ", address(roleManager));
        console2.log("DefaultPassHook    ", address(hook));
        console2.log("KYBGateway         ", address(kyb));
        console2.log("IssuerRegistry     ", address(issuers));
        console2.log("ComplianceRegistry ", address(compliance));
        console2.log("ParameterArchive   ", address(archive));
        console2.log("CollateralRegistry ", address(collateralRegistry));
        console2.log("DealRegistry       ", address(dealRegistry));
        console2.log("EscrowVault        ", address(vault));
        console2.log("SettlementRouter   ", address(router));
        console2.log("LendingEngine      ", address(engine));
        console2.log("LiquidationHandler ", address(handler));
        console2.log("PortfolioLens      ", address(lens));
    }
}
