// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RoleManager} from "../../src/l1/RoleManager.sol";
import {DefaultPassHook} from "../../src/l1/DefaultPassHook.sol";
import {KYBGateway} from "../../src/l1/KYBGateway.sol";
import {IssuerRegistry} from "../../src/l1/IssuerRegistry.sol";
import {ComplianceRegistry} from "../../src/l1/ComplianceRegistry.sol";
import {ParameterArchive} from "../../src/l2/ParameterArchive.sol";
import {CollateralRegistry} from "../../src/l2/CollateralRegistry.sol";
import {DealRegistry} from "../../src/l3/DealRegistry.sol";
import {EscrowVault} from "../../src/l3/EscrowVault.sol";
import {LendingEngine} from "../../src/l3/LendingEngine.sol";
import {LiquidationHandler} from "../../src/l4/LiquidationHandler.sol";
import {SettlementRouter} from "../../src/l4/SettlementRouter.sol";
import {PortfolioLens} from "../../src/l5/PortfolioLens.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Roles} from "../../src/libraries/Roles.sol";

/// @notice Wiring + role-grant fixture for fork tests.
///
/// Layout:
///   - Mainnet fork pinned to a block AFTER the Chainlink feeds used in
///     tests are deployed (USDC/USD, BTC/USD, ETH/USD, USDT/USD).
///   - Deploys all 13 contracts in the order documented in
///     `docs/Claude-architechture-3.md` §24.
///   - Grants each application role to a designated test EOA so test
///     methods can `vm.prank(...)` to operate as that role.
abstract contract ProtocolFixture is Test {
    // ---- mainnet token addresses ----
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // 6 dec
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 6 dec
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 8 dec
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // 18 dec
    address internal constant DAI  = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // 18 dec

    // ---- mainnet Chainlink feeds (USD-denominated, 8 decimals each) ----
    address internal constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address internal constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23; // 8 dec
    address internal constant FEED_BTC_USD  = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // 8 dec
    address internal constant FEED_ETH_USD  = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // 8 dec
    address internal constant FEED_DAI_USD  = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9; // 8 dec

    // ---- test actors ----
    uint256 internal constant LENDER_PK = 0xA11CE;
    uint256 internal constant BORROWER_PK = 0xB0B0B0;
    uint256 internal constant AMINA_PK = 0xA50A50;
    uint256 internal constant ATTESTOR_PK = 0xA77357;
    address internal LENDER;
    address internal BORROWER;
    address internal AMINA_SIGNER;
    address internal ATTESTOR;

    address internal GOVERNOR = makeAddr("Governor");
    address internal CURATOR_ADDR = makeAddr("Curator");
    address internal ALLOCATOR_ADDR = makeAddr("Allocator");
    address internal LIQUIDATOR_ADDR = makeAddr("Liquidator");
    address internal OPS_ADDR = makeAddr("Ops");
    address internal GUARDIAN_ADDR = makeAddr("Guardian");
    address internal EMERGENCY_ADDR = makeAddr("Emergency");
    address internal ORACLE_ADMIN_ADDR = makeAddr("OracleAdmin");
    address internal CUSTODIAN = makeAddr("Custodian");
    address internal AMINA_TREASURY = makeAddr("AminaTreasury");

    // ---- deployed protocol ----
    RoleManager internal roleManager;
    DefaultPassHook internal defaultHook;
    KYBGateway internal kyb;
    IssuerRegistry internal issuers;
    ComplianceRegistry internal compliance;
    ParameterArchive internal archive;
    CollateralRegistry internal collateralRegistry;
    DealRegistry internal dealRegistry;
    EscrowVault internal vault;
    LendingEngine internal engine;
    LiquidationHandler internal handler;
    SettlementRouter internal router;
    PortfolioLens internal lens;

    function _forkAt() internal view virtual returns (uint256) {
        // 0 = "use HEAD" — public RPCs prune historical state aggressively
        // so we follow the chain head unless the caller pinned a block.
        return vm.envOr("FORK_BLOCK", uint256(0));
    }

    function _setUpFork() internal {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 blk = _forkAt();
        if (blk == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, blk);
        }

        LENDER = vm.addr(LENDER_PK);
        BORROWER = vm.addr(BORROWER_PK);
        AMINA_SIGNER = vm.addr(AMINA_PK);
        ATTESTOR = vm.addr(ATTESTOR_PK);

        vm.label(LENDER, "Lender");
        vm.label(BORROWER, "Borrower");
        vm.label(AMINA_SIGNER, "AminaSigner");
        vm.label(ATTESTOR, "Attestor");
        vm.label(GOVERNOR, "Governor");
        vm.label(CURATOR_ADDR, "Curator");
        vm.label(ALLOCATOR_ADDR, "Allocator");
        vm.label(LIQUIDATOR_ADDR, "Liquidator");
        vm.label(USDC, "USDC");
        vm.label(USDT, "USDT");
        vm.label(WBTC, "WBTC");
        vm.label(WETH, "WETH");

        _deployAll();
        _grantRoles();
        _bootstrapKyb();
    }

    function _deployAll() internal {
        // 1) RoleManager (immutable, no proxy). Bootstrap admin = this test contract.
        roleManager = new RoleManager(address(this));

        // 2) DefaultPassHook (immutable).
        defaultHook = new DefaultPassHook();

        // 3) KYBGateway proxy.
        KYBGateway kybImpl = new KYBGateway();
        kyb = KYBGateway(
            address(new ERC1967Proxy(address(kybImpl), abi.encodeCall(KYBGateway.initialize, (address(roleManager)))))
        );

        // 4) IssuerRegistry proxy.
        IssuerRegistry irImpl = new IssuerRegistry();
        issuers = IssuerRegistry(
            address(
                new ERC1967Proxy(
                    address(irImpl), abi.encodeCall(IssuerRegistry.initialize, (address(roleManager)))
                )
            )
        );

        // 5) ComplianceRegistry proxy.
        ComplianceRegistry crImpl = new ComplianceRegistry();
        compliance = ComplianceRegistry(
            address(
                new ERC1967Proxy(
                    address(crImpl),
                    abi.encodeCall(ComplianceRegistry.initialize, (address(roleManager), address(defaultHook)))
                )
            )
        );

        // 6) DealRegistry needs engine; defer to pass 2. EscrowVault needs engine bind; defer.

        // First, predict engine + handler addresses so we can deploy
        // ParameterArchive / DealRegistry / Vault / SettlementRouter with
        // a one-shot binder pattern.

        // 7) ParameterArchive (needs collateralRegistry). Forward-declare
        // collateralRegistry by deploying its impl first and computing
        // the proxy address.
        CollateralRegistry collImpl = new CollateralRegistry();
        // We need archive's collateralRegistry constructor argument. We
        // can't know the CollateralRegistry proxy address yet — we
        // deploy the proxy AFTER the archive but tell the archive a
        // predicted address via vm.computeCreateAddress.
        uint256 nonce = vm.getNonce(address(this));
        address predictedColl = vm.computeCreateAddress(address(this), nonce + 1); // next is archive, then proxy
        archive = new ParameterArchive(predictedColl);
        collateralRegistry = CollateralRegistry(
            address(
                new ERC1967Proxy(
                    address(collImpl),
                    abi.encodeCall(CollateralRegistry.initialize, (address(roleManager), address(archive)))
                )
            )
        );
        require(address(collateralRegistry) == predictedColl, "predicted address mismatch");

        // 8) DealRegistry (immutable) needs engine address. Predict it.
        // Sequence below: vault → router → engineImpl → engineProxy.
        nonce = vm.getNonce(address(this));
        // Next deploy is EscrowVault, then SettlementRouter, then LendingEngine impl, then LendingEngine proxy.
        // engineProxy = createAddress(this, nonce + 3)
        address predictedEngine = vm.computeCreateAddress(address(this), nonce + 4);
        dealRegistry = new DealRegistry(predictedEngine);

        // 9) EscrowVault (immutable). Governor binds engine after engine proxy exists.
        vault = new EscrowVault(GOVERNOR);

        // 10) SettlementRouter (immutable). Binder = address(this); will bind engine + handler later.
        router = new SettlementRouter(address(this));

        // 11) LendingEngine proxy.
        LendingEngine engineImpl = new LendingEngine();
        // We'll pass the handler proxy address into init AFTER deploying
        // the handler — predict it.
        // nonce sequence after engineImpl: engine proxy, handler impl, handler proxy
        nonce = vm.getNonce(address(this));
        address predictedHandler = vm.computeCreateAddress(address(this), nonce + 2);
        engine = LendingEngine(
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
        require(address(engine) == predictedEngine, "predicted engine address mismatch");

        // 12) LiquidationHandler proxy.
        LiquidationHandler handlerImpl = new LiquidationHandler();
        handler = LiquidationHandler(
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
                                attestor: ATTESTOR,
                                aminaTreasury: AMINA_TREASURY,
                                attestationStaleSecs: 10 minutes
                            })
                        )
                    )
                )
            )
        );
        require(address(handler) == predictedHandler, "predicted handler address mismatch");

        // 13) Bind vault → engine, bind router → engine + handler, bind issuers → engine.
        vm.prank(GOVERNOR);
        vault.bindEngine(address(engine));
        router.bind(address(engine), address(handler));
        // issuers.bindEngine is `restricted` — call it as this (admin).
        issuers.bindEngine(address(engine));

        // 14) PortfolioLens (immutable).
        lens = new PortfolioLens(address(engine), address(dealRegistry), address(vault));
    }

    function _grantRoles() internal {
        // Define application roles + their target selectors.
        // The bootstrap admin (this contract) calls labelRole / grantRole
        // then revokes itself.

        roleManager.labelRole(Roles.GOVERNOR, "GOVERNOR");
        roleManager.labelRole(Roles.EMERGENCY, "EMERGENCY");
        roleManager.labelRole(Roles.CURATOR, "CURATOR");
        roleManager.labelRole(Roles.ALLOCATOR, "ALLOCATOR");
        roleManager.labelRole(Roles.LIQUIDATOR, "LIQUIDATOR");
        roleManager.labelRole(Roles.GUARDIAN, "GUARDIAN");
        roleManager.labelRole(Roles.OPS, "OPS");
        roleManager.labelRole(Roles.ORACLE_ADMIN, "ORACLE_ADMIN");

        roleManager.grantRole(Roles.GOVERNOR, GOVERNOR, 0);
        roleManager.grantRole(Roles.EMERGENCY, EMERGENCY_ADDR, 0);
        roleManager.grantRole(Roles.CURATOR, CURATOR_ADDR, 0);
        roleManager.grantRole(Roles.ALLOCATOR, ALLOCATOR_ADDR, 0);
        roleManager.grantRole(Roles.LIQUIDATOR, LIQUIDATOR_ADDR, 0);
        roleManager.grantRole(Roles.GUARDIAN, GUARDIAN_ADDR, 0);
        roleManager.grantRole(Roles.OPS, OPS_ADDR, 0);
        roleManager.grantRole(Roles.ORACLE_ADMIN, ORACLE_ADMIN_ADDR, 0);

        // Wire role → contract+selector access. We use a single CURATOR
        // role for all setters across L1 + L2 contracts to keep the
        // fixture compact; production deployments would split per the
        // matrix in v3 §7.

        _bindRoleToSelectors(Roles.CURATOR, address(kyb), _kybSelectors());
        _bindRoleToSelectors(Roles.CURATOR, address(issuers), _issuersSelectors());
        _bindRoleToSelectors(Roles.CURATOR, address(compliance), _complianceSelectors());
        _bindRoleToSelectors(Roles.CURATOR, address(collateralRegistry), _collateralSelectors());

        // ALLOCATOR can openAndActivate.
        bytes4[] memory allocSel = new bytes4[](1);
        allocSel[0] = LendingEngine.openAndActivate.selector;
        _bindRoleToSelectors(Roles.ALLOCATOR, address(engine), allocSel);

        // LIQUIDATOR can call handler steps.
        bytes4[] memory liqSel = new bytes4[](3);
        liqSel[0] = LiquidationHandler.warn.selector;
        liqSel[1] = LiquidationHandler.partialLiquidate.selector;
        liqSel[2] = LiquidationHandler.fullLiquidate.selector;
        _bindRoleToSelectors(Roles.LIQUIDATOR, address(handler), liqSel);

        // Engine admin functions go to GOVERNOR.
        bytes4[] memory engineAdmin = new bytes4[](5);
        engineAdmin[0] = LendingEngine.setGlobalCapUsd.selector;
        engineAdmin[1] = LendingEngine.setBorrowerCapUsd.selector;
        engineAdmin[2] = LendingEngine.setLenderCapUsd.selector;
        engineAdmin[3] = LendingEngine.pauseDeal.selector;
        engineAdmin[4] = LendingEngine.unpauseDeal.selector;
        _bindRoleToSelectors(Roles.GOVERNOR, address(engine), engineAdmin);

        // EMERGENCY can globally halt / force oracle override / sealed mode.
        bytes4[] memory emerg = new bytes4[](3);
        emerg[0] = LendingEngine.setGlobalHalt.selector;
        emerg[1] = LendingEngine.setEmergencySealed.selector;
        emerg[2] = LendingEngine.forceOracleOverride.selector;
        _bindRoleToSelectors(Roles.EMERGENCY, address(engine), emerg);

        // Handler admin → GOVERNOR.
        bytes4[] memory handlerAdmin = new bytes4[](3);
        handlerAdmin[0] = LiquidationHandler.setAttestor.selector;
        handlerAdmin[1] = LiquidationHandler.setAminaTreasury.selector;
        handlerAdmin[2] = LiquidationHandler.setAttestationStaleSecs.selector;
        _bindRoleToSelectors(Roles.GOVERNOR, address(handler), handlerAdmin);
    }

    function _bindRoleToSelectors(uint64 role, address target, bytes4[] memory selectors) internal {
        roleManager.setTargetFunctionRole(target, selectors, role);
    }

    function _kybSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = KYBGateway.setStatus.selector;
    }

    function _issuersSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = IssuerRegistry.addIssuer.selector;
        s[1] = IssuerRegistry.setIssuerStatus.selector;
        s[2] = IssuerRegistry.runAdmissionChecks.selector;
        s[3] = IssuerRegistry.addToken.selector;
        s[4] = IssuerRegistry.pauseToken.selector;
        s[5] = IssuerRegistry.enableDualUse.selector;
        s[6] = IssuerRegistry.setCapUsd.selector;
        s[7] = IssuerRegistry.bindEngine.selector;
    }

    function _complianceSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = ComplianceRegistry.registerHook.selector;
        s[1] = ComplianceRegistry.setDefaultHook.selector;
    }

    function _collateralSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = CollateralRegistry.addPair.selector;
        s[1] = CollateralRegistry.updatePair.selector;
        s[2] = CollateralRegistry.pausePair.selector;
    }

    /// @notice external wrapper around `deal(token, to, amount, true)` so
    ///         we can `try/catch` it (try/catch requires an external call).
    function dealAdjust(address token, address to, uint256 amount) external {
        require(msg.sender == address(this), "only-self");
        deal(token, to, amount, true);
    }

    function _bootstrapKyb() internal {
        // Approve LENDER + BORROWER for testing.
        vm.startPrank(CURATOR_ADDR);
        kyb.setStatus(LENDER, Types.KybStatus.Approved, 0, bytes32("docsLender"), bytes32("CH"));
        kyb.setStatus(BORROWER, Types.KybStatus.Approved, 0, bytes32("docsBorrower"), bytes32("CH"));
        vm.stopPrank();
    }

    // ---------- token admission helpers ----------

    /// @notice Run admission checks + add a token using its on-chain decimals.
    function _admitAndAddToken(address token, Types.TokenKind kind, address issuer_, uint256 capUsd) internal {
        // Decimals via call (token must implement IERC20Metadata).
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, "decimals() failed");
        uint8 dec = abi.decode(data, (uint8));

        // Fund CURATOR with the token. WETH (and a few other tokens)
        // don't fit stdStorage's totalSupply detection, so try the
        // adjust-balance form first and fall back to the simple form.
        try this.dealAdjust(token, CURATOR_ADDR, 2e9) {} catch {
            deal(token, CURATOR_ADDR, 2e9);
        }
        vm.startPrank(CURATOR_ADDR);
        // Low-level approve for USDT-like tokens that don't return bool.
        (bool _ok, ) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(issuers), type(uint256).max));
        require(_ok, "approve failed");
        (bool pass, bytes32 reason) = issuers.runAdmissionChecks(token, dec);
        require(pass, string(abi.encodePacked("admission failed: ", reason)));
        Types.TokenInfo memory info = Types.TokenInfo({
            issuer: issuer_,
            kind: kind,
            dualUseEnabled: false,
            decimals: dec,
            paused: false,
            capUsd: capUsd,
            usedCapUsd: 0,
            redemptionAttestationHash: keccak256(abi.encode(token, "redeem")),
            nonStandardChecked: false // overwritten by addToken
        });
        issuers.addToken(token, info);
        vm.stopPrank();
    }
}
