// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {StreamFactory} from "../../src/StreamFactory.sol";
import {StreamVault} from "../../src/StreamVault.sol";

/// @dev minimal ERC20 with a settable balance/allowance map (approve/transferFrom), no deps.
contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }
    function transfer(address to, uint256 v) external returns (bool) { balanceOf[msg.sender] -= v; balanceOf[to] += v; return true; }
    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v; balanceOf[f] -= v; balanceOf[to] += v; return true;
    }
}

/// @dev A CONTRACT recipient that reverts on native receive until told otherwise — proves `rescue`
///      uses a full `call{value}`, not the 2300-gas `.transfer()` stipend.
contract Reverter {
    bool public ok;
    receive() external payable { if (!ok) revert("no"); }
    function accept(bool v) external { ok = v; }
}

/// @title The DEAD-DROP fix, PROVEN. The shape: a factory that ACCEPTS value but cannot MOVE its own
///        balance. v1 stranded 5.01 USDC live; v2 carried the same latent hole. Each test drives the
///        NEW surface (receive / rescue / createStreamSelfFunded) and asserts the SIDE EFFECT, plus a
///        negcontrol that re-injects the v1 hole through the REAL path.
contract RescueDeadDrop is Test {
    StreamFactory f;
    Tok usdc;
    address owner = address(0xA11CE);
    address feeTo = address(0xFEE);
    address payer = address(0x5B5);
    address merchant = address(0x2733);
    address stranger = address(0xBAD);
    address sink = address(0xCAFE);
    uint64 T0;

    function setUp() public {
        vm.warp(1_800_000_000);
        T0 = uint64(block.timestamp);
        f = new StreamFactory(owner, feeTo, 500);
        usdc = new Tok();
    }

    // =============================== (1) ERC20 dead-drop ===============================

    /// A bare ERC20 send to the factory used to succeed-but-strand. Now it can be RESCUED.
    function test_erc20BareSend_thenRescue_movesExactBalance() public {
        usdc.mint(stranger, 5_010_000);
        vm.prank(stranger);
        usdc.transfer(address(f), 5_010_000);              // the mistake: transfer TO the factory
        assertEq(usdc.balanceOf(address(f)), 5_010_000, "factory holds the stray");

        uint256 sinkBefore = usdc.balanceOf(sink);
        vm.prank(owner);
        uint256 got = f.rescue(address(usdc), sink);

        assertEq(got, 5_010_000, "rescue returned the exact balance");
        assertEq(usdc.balanceOf(address(f)), 0, "factory drained to 0");
        assertEq(usdc.balanceOf(sink) - sinkBefore, 5_010_000, "sink ROSE by exactly that"); // side-effect
    }

    // =============================== (2) native dead-drop ===============================

    /// A bare native send no longer reverts (receive/fallback present) and can be RESCUED.
    function test_nativeBareSend_accepted_thenRescue_forwards() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, ) = address(f).call{value: 1 ether}("");   // bare send, empty calldata -> receive()
        assertTrue(ok, "bare native send accepted (receive/fallback)");
        assertEq(address(f).balance, 1 ether, "factory holds the native");

        vm.prank(owner);
        uint256 got = f.rescue(address(0), sink);
        assertEq(got, 1 ether, "rescue returned the native balance");
        assertEq(address(f).balance, 0, "factory native drained");
        assertEq(sink.balance, 1 ether, "sink received the native");
    }

    /// `rescue` native uses a full call, so a contract sink needing >2300 gas still works.
    function test_rescueNative_revertingSinkUntilAccept() public {
        Reverter rv = new Reverter();
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok1, ) = address(f).call{value: 1 ether}("");
        assertTrue(ok1);
        vm.prank(owner);
        vm.expectRevert(bytes("native send failed"));
        f.rescue(address(0), address(rv));                  // still-reverting sink -> honest revert
        rv.accept(true);
        vm.prank(owner);
        f.rescue(address(0), address(rv));
        assertEq(address(rv).balance, 1 ether, "delivered once the sink accepts");
    }

    // =============================== (3) self-fund leg ===============================

    /// The factory's OWN held balance can be turned straight into a stream (no rescue round-trip).
    function test_selfFund_mintsVaultFromFactoryOwnBalance_noAllowance() public {
        usdc.mint(stranger, 5_000_000);
        vm.prank(stranger);
        usdc.transfer(address(f), 5_000_000);               // stray funds land on the factory

        uint64 s = T0; uint64 e = T0 + 1_000;
        uint256 vaultBefore = usdc.balanceOf(address(f));
        vm.prank(payer);                                    // payer identity; NO approve anywhere
        address vault = f.createStreamSelfFunded(payer, merchant, address(usdc), 5_000_000, s, e);

        assertEq(usdc.balanceOf(vault), 5_000_000, "vault funded from the factory's own balance");
        assertEq(usdc.balanceOf(address(f)), vaultBefore - 5_000_000, "factory fell by exactly the ticket");
        assertEq(usdc.allowance(payer, address(f)), 0, "selfFund needed NO payer allowance");
        assertEq(StreamVault(payable(vault)).recipient(), merchant, "right recipient bound");
    }

    /// Native self-fund: the factory already holds the native, so msg.value MUST be 0.
    function test_selfFund_native_requiresZeroMsgValue() public {
        vm.deal(stranger, 2 ether);
        vm.deal(payer, 1 ether);                            // so the {value:1} attempt has funds to send
        vm.prank(stranger);
        (bool ok2, ) = address(f).call{value: 2 ether}("");
        assertTrue(ok2);
        uint64 s = T0; uint64 e = T0 + 1_000;

        vm.prank(payer);
        vm.expectRevert(StreamFactory.FundingFailed.selector);
        f.createStreamSelfFunded{value: 1}(payer, merchant, address(0), 1 ether, s, e);  // non-zero value

        vm.prank(payer);
        address vault = f.createStreamSelfFunded(payer, merchant, address(0), 1 ether, s, e);
        assertEq(vault.balance, 1 ether, "native stream funded from factory balance");
        assertEq(address(f).balance, 1 ether, "factory fell by exactly the ticket");
    }

    // =============================== (4) negcontrols ===============================

    /// NC-a: rescue is owner-only.
    function test_NC_rescue_nonOwnerReverts() public {
        usdc.mint(address(f), 1_000_000);
        vm.prank(stranger);
        vm.expectRevert(StreamFactory.NotOwner.selector);
        f.rescue(address(usdc), sink);
    }

    /// NC-b: rescue with nothing held is a CLEAN no-op (returns 0, no revert).
    function test_NC_rescueZeroBalance_isCleanNoOp() public {
        vm.prank(owner);
        uint256 got = f.rescue(address(usdc), sink);
        assertEq(got, 0, "zero-balance rescue returns 0 and does not revert");
        assertEq(usdc.balanceOf(sink), 0, "nothing moved");
    }

    /// NC-c: zero `to` reverts.
    function test_NC_rescueZeroToReverts() public {
        usdc.mint(address(f), 1);
        vm.prank(owner);
        vm.expectRevert(StreamFactory.ZeroArg.selector);
        f.rescue(address(usdc), address(0));
    }

    /// NC-d: rescuing the factory's own held balance NEVER touches a live stream's money. A stream's
    /// funds sit in the VAULT (pulled payer->vault directly); the factory holds only the stray.
    function test_NC_rescueDoesNotTouchStreamMoney() public {
        usdc.mint(payer, 7_000_000);
        vm.prank(payer);
        usdc.approve(address(f), type(uint256).max);
        uint64 s = T0; uint64 e = T0 + 1_000;
        vm.prank(payer);
        address vault = f.createStream(merchant, address(usdc), 5_000_000, s, e);
        assertEq(usdc.balanceOf(vault), 5_000_000, "stream funded in the vault");

        // a stray lands on the FACTORY, then is rescued away
        usdc.mint(address(f), 1_234_567);
        vm.prank(owner);
        f.rescue(address(usdc), sink);

        assertEq(usdc.balanceOf(vault), 5_000_000, "stream money UNTOUCHED by the rescue");
        assertEq(usdc.balanceOf(sink), 1_234_567, "only the stray moved");
        // and the stream still settles
        vm.warp(e);
        vm.prank(merchant);
        StreamVault(payable(vault)).withdraw();
        assertGt(usdc.balanceOf(merchant), 0, "stream still pays after a rescue");
    }

    // =============================== (5) the v1 hole, re-injected ===============================

    /// NC-e — THE EXACT v1 HOLE, PROVEN. A pre-patch (v1-shaped) factory accepts an ERC20 send but
    /// cannot turn it into a stream: `createStreamFor(payer=factory)` pulls via `transferFrom`, which
    /// needs `allowance[factory][factory]` — and the factory has NO approve fn, so it is 0 → "pull
    /// failed". The patched `createStreamSelfFunded` closes it with NO allowance. Proven by running
    /// the identical intent both ways on the SAME input.
    function test_NC_v1SelfFundHole_provenClosedBySelfFundedLeg() public {
        V1NoRescue v1 = new V1NoRescue(owner, feeTo, 500);
        usdc.mint(stranger, 5_000_000);
        vm.prank(stranger);
        usdc.transfer(address(v1), 5_000_000);              // stray lands on the v1 factory
        assertEq(usdc.balanceOf(address(v1)), 5_000_000, "v1 holds the stray (token side succeeds)");

        uint64 s = T0; uint64 e = T0 + 1_000;
        // v1 has no receive/rescue AND no self-fund: trying to stream the factory's own funds reverts
        // because allowance[factory][factory] == 0.
        vm.prank(payer);
        vm.expectRevert(bytes("pull failed"));
        v1.createStreamFor(address(v1), merchant, address(usdc), 5_000_000, s, e);
        assertEq(usdc.balanceOf(address(v1)), 5_000_000, "v1: the stray is STRANDED (still there)");

        // the patched factory, identical intent, NO allowance -> succeeds
        usdc.mint(stranger, 5_000_000);
        vm.prank(stranger);
        usdc.transfer(address(f), 5_000_000);
        vm.prank(payer);
        address vault = f.createStreamSelfFunded(payer, merchant, address(usdc), 5_000_000, s, e);
        assertEq(usdc.balanceOf(vault), 5_000_000, "v2.1: the stray became a live stream");
        assertEq(usdc.balanceOf(address(f)), 0, "v2.1: factory drained into the stream");
    }

    /// NC-f: a v1-shaped factory REVERTS a bare native send (no receive/fallback) — the shape itself.
    function test_NC_v1BareNativeSendReverts() public {
        V1NoRescue v1 = new V1NoRescue(owner, feeTo, 500);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, ) = address(v1).call{value: 1 ether}("");
        assertFalse(ok, "v1 REJECTS a bare native send (no receive/fallback)");
    }
}

/// @dev The EXACT pre-patch factory shape (no receive/fallback/rescue/selfFund): funds only by pull.
///      Minimal, but its create path is the real one so NC-e is a re-injection, not a hand-assertion.
contract V1NoRescue {
    address public owner;
    address public feeRecipient;
    uint16 public feeBps;
    uint256 public minFee;
    mapping(address => uint256) public nonce;

    struct Stream { address payer; address recipient; address token; uint256 amount; uint64 start; uint64 end; bytes32 salt; uint256 index; }

    constructor(address o, address fr, uint16 fb) { owner = o; feeRecipient = fr; feeBps = fb; }

    function createStreamFor(address payer, address recipient, address token, uint256 amount, uint64 start, uint64 end)
        public payable returns (address vault)
    {
        uint256 idx = nonce[payer]++;
        Stream memory s = Stream(payer, recipient, token, amount, start, end, 0, idx);
        s.salt = keccak256(abi.encodePacked(s.payer, s.index, s.recipient, s.token, s.start, s.end));
        bytes memory ic = abi.encodePacked(type(StreamVault).creationCode,
            abi.encode(address(this), s.payer, s.recipient, s.token, s.amount, s.start, s.end, s.salt, s.index));
        bytes32 h = keccak256(abi.encodePacked(hex"ff", address(this), s.salt, keccak256(ic)));
        vault = address(uint160(uint256(h)));
        bytes32 salt = s.salt;
        assembly { let inst := create2(0, add(ic, 0x20), mload(ic), salt) if iszero(inst) { revert(0,0) } }
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, payer, vault, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "pull failed");
    }
}
