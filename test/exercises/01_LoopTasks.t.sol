// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {Vault} from "../../src/Vault.sol";

/// @title Ex2 + Ex4 — decimal handling, permissions and pausing
/// @notice These tests separate correct token accounting from correct interpretation of
///         units, and distinguish unauthorized callers from privileged token operations.
/// @dev Acceptance: make exercise. Exact revert selectors ensure negative tests fail
///      for the intended permission or pause check rather than an unrelated error.
contract LoopTasksTest is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockUSDC();
        stable = new SimpleStablecoin(admin);
        vault = new Vault(usdc, stable);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));
    }

    // ==================================================================
    // Ex2 · the decimals trap: a 6-decimal stablecoin meets 18-decimal intuition
    // ==================================================================

    /// @dev Restrict fuzz inputs to positive amounts below one million tokens so deposits
    ///      exercise valid accounting rather than the zero-amount guard. Comparing the
    ///      supply delta with the input detects scaling errors in the 1:1 minting path.
    function test_Ex2_DepositIncreasesSupplyByExactly(uint96 raw) public {
        uint256 amount = uint256(raw) % 1_000_000e6;
        vm.assume(amount > 0);
        uint256 supplyBefore = stable.totalSupply();
        _deposit(alice, amount);
        assertEq(stable.totalSupply() - supplyBefore, amount);
        assertEq(stable.balanceOf(alice), amount);
        assertEq(vault.totalCollateral(), stable.totalSupply());
    }

    /// @dev The faucet supplies the mistaken amount so insufficient funds cannot hide
    ///      the unit error. Equal supply and collateral still hold: they compare raw units,
    ///      not user intent. With 6 decimals, 1000e18 represents 10^15 tokens, not 1000.
    function test_Ex2_DecimalsTrap() public {
        uint256 mistakenAmount = 1000e18;
        _deposit(alice, mistakenAmount);
        assertEq(usdc.decimals(), 6);
        assertEq(stable.decimals(), 6);
        assertEq(stable.balanceOf(alice), mistakenAmount);
        assertEq(stable.totalSupply(), vault.totalCollateral());
        assertEq(mistakenAmount / 1e6, 1e15, "human-readable token amount");
        assertEq(mistakenAmount / 1000e6, 1e12, "unit mistake: a trillion times too large");
    }

    // ==================================================================
    // Ex4 · permissions and pausing: where the guard is, who holds the key
    // ==================================================================

    /// @dev Matching both caller and role in the access-control error proves the mint is
    ///      rejected for missing authority, rather than an invalid recipient or amount.
    function test_Ex4_Mint_RevertsForNonMinter() public {
        bytes32 role = stable.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role
            )
        );
        vm.prank(attacker);
        stable.mint(attacker, 1000e6);
        assertEq(stable.totalSupply(), 0);
    }

    /// @dev Fund Alice before pausing so a failed transfer demonstrates the pause guard,
    ///      not insufficient balance; unchanged balances also rule out partial movement.
    function test_Ex4_Pause_BlocksTransfers() public {
        _deposit(alice, 1000e6);
        stable.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        stable.transfer(attacker, 1e6);
        assertEq(stable.balanceOf(alice), 1000e6);
        assertEq(stable.balanceOf(attacker), 0);
    }

    /// @dev Redemption burns through _update, so the token pause also closes the exit to
    ///      collateral. Checking both token balances and reserves confirms the failed burn
    ///      cannot pay collateral or partially redeem (STUDENT-QUESTIONS.md B1/B2).
    function test_Ex4_Pause_BlocksRedeem() public {
        _deposit(alice, 1000e6);
        stable.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.redeem(100e6);
        assertEq(stable.balanceOf(alice), 1000e6);
        assertEq(vault.totalCollateral(), 1000e6);
        assertEq(usdc.balanceOf(alice), 0);
    }

    /// @dev Give Alice a real balance so rejection proves the role guard protects an
    ///      existing holder rather than merely failing to burn an empty account.
    function test_Ex4_AttackerCannotBurnOthersBalance() public {
        _deposit(alice, 1000e6);
        bytes32 role = stable.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role
            )
        );
        vm.prank(attacker);
        stable.burn(alice, 100e6);
        assertEq(stable.balanceOf(alice), 1000e6);
    }

    /// @dev Mint and burn share MINTER_ROLE, giving the vault more token-level authority
    ///      than caller-only redemption needs. Impersonating it isolates this permission
    ///      risk; it does not prove a public Vault function can burn arbitrary holders.
    function test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance() public {
        _deposit(alice, 1000e6);
        assertTrue(stable.hasRole(stable.MINTER_ROLE(), address(vault)));
        // Impersonation demonstrates the role's power, not a reachable Vault entry point.
        vm.prank(address(vault));
        stable.burn(alice, 100e6);
        assertEq(stable.balanceOf(alice), 900e6);
        assertEq(stable.totalSupply(), 900e6);
        assertEq(vault.totalCollateral(), 1000e6);
    }

    function _deposit(address user, uint256 amount) internal {
        usdc.faucet(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}
