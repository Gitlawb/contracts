// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "lib/forge-std/src/Test.sol";
import {Incinerator} from "src/Incinerator.sol";

/// Standard ERC-20 (returns bool).
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// USDT-style token: transferFrom returns NOTHING (no bool).
contract MockNoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // no return value
    }
}

/// Token whose permit() simply grants allowance (stands in for EIP-2612).
contract MockPermitERC20 is MockERC20 {
    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32)
        external
    {
        allowance[owner][spender] = value;
    }
}

contract IncineratorTest is Test {
    Incinerator internal inc;
    MockERC20 internal token;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    event Incinerated(
        address indexed burner,
        address indexed token,
        uint256 amount,
        address indexed referrer,
        uint256 timestamp
    );

    function setUp() public {
        inc = new Incinerator();
        token = new MockERC20();
        token.mint(alice, 1_000e18);
    }

    function test_incinerate_sendsToDeadAndEmits() public {
        vm.prank(alice);
        token.approve(address(inc), 100e18);

        vm.expectEmit(true, true, true, true);
        emit Incinerated(alice, address(token), 100e18, bob, block.timestamp);

        vm.prank(alice);
        inc.incinerate(address(token), 100e18, bob);

        assertEq(token.balanceOf(DEAD), 100e18, "tokens reached dead");
        assertEq(token.balanceOf(alice), 900e18, "burner debited");
    }

    function test_incinerate_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(Incinerator.ZeroAmount.selector);
        inc.incinerate(address(token), 0, bob);
    }

    function test_incinerate_selfReferralZeroed() public {
        vm.prank(alice);
        token.approve(address(inc), 10e18);

        vm.expectEmit(true, true, true, true);
        emit Incinerated(alice, address(token), 10e18, address(0), block.timestamp);

        vm.prank(alice);
        inc.incinerate(address(token), 10e18, alice); // referrer == self → zeroed
    }

    function test_incinerate_insufficientAllowanceReverts() public {
        // No approval → transferFrom underflows/reverts → TransferFailed.
        vm.prank(alice);
        vm.expectRevert(Incinerator.TransferFailed.selector);
        inc.incinerate(address(token), 100e18, bob);
    }

    function test_incinerate_nonStandardToken() public {
        MockNoReturnERC20 usdt = new MockNoReturnERC20();
        usdt.mint(alice, 500e18);
        vm.prank(alice);
        usdt.approve(address(inc), 250e18);

        vm.prank(alice);
        inc.incinerate(address(usdt), 250e18, bob);

        assertEq(usdt.balanceOf(DEAD), 250e18, "non-standard token burned");
    }

    function test_incinerateWithPermit_singleTx() public {
        MockPermitERC20 ptoken = new MockPermitERC20();
        ptoken.mint(alice, 100e18);

        // No prior approve; permit inside the call grants allowance.
        vm.prank(alice);
        inc.incinerateWithPermit(address(ptoken), 40e18, bob, block.timestamp + 1, 0, 0, 0);

        assertEq(ptoken.balanceOf(DEAD), 40e18, "burned via permit in one tx");
    }

    function test_incinerateWithPermit_permitRevertFallsThrough() public {
        // Standard token has no permit(); the try/catch swallows the failure,
        // and a prior approval lets the burn proceed anyway.
        vm.prank(alice);
        token.approve(address(inc), 30e18);

        vm.prank(alice);
        inc.incinerateWithPermit(address(token), 30e18, bob, block.timestamp + 1, 0, 0, 0);

        assertEq(token.balanceOf(DEAD), 30e18, "burned despite permit revert");
    }

    function testFuzz_incinerate(uint256 amount, address referrer) public {
        amount = bound(amount, 1, 1_000e18);
        token.mint(alice, amount); // ensure balance
        vm.prank(alice);
        token.approve(address(inc), amount);

        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(alice);
        inc.incinerate(address(token), amount, referrer);
        assertEq(token.balanceOf(DEAD), deadBefore + amount);
    }
}
