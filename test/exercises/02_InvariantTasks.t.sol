// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {Vault} from "../../src/Vault.sol";

/// @title Ex6 — invariant testing
/// @notice Random deposit/redeem sequences check accounting across operation orders
///         that isolated examples may miss, with balances carried between calls.
/// @dev Acceptance: make exercise. The handler bounds inputs to valid user operations
///      so the campaign explores state changes instead of mostly reverting. Its scope
///      excludes direct token transfers, privileged issuance and role changes.
contract VaultHandler is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;

    address[3] public users;

    /// @dev Count completed operations, excluding early returns, to help inspect whether
    ///      a campaign exercised accounting. The invariants do not assert these counters.
    uint256 public ghost_deposits;
    uint256 public ghost_redeems;

    constructor(MockUSDC usdc_, SimpleStablecoin stable_, Vault vault_) {
        usdc = usdc_;
        stable = stable_;
        vault = vault_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 1_000_000e6);
        }
    }

    /// @dev Bound deposits by the selected user's funds to avoid irrelevant balance
    ///      failures. Approving as that user permits Vault's collateral transferFrom.
    function deposit(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        ghost_deposits++;
    }

    /// @notice Ex6.1 — redemption within the selected user's balance
    /// @dev Skip empty balances because no positive redeem amount exists. Bounding the
    ///      amount keeps the campaign on valid state transitions. No sUSD approval is
    ///      needed: the vault burns the caller's tokens using its MINTER_ROLE.
    function redeem(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];
        uint256 balance = stable.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(user);
        vault.redeem(amount);
        ghost_redeems++;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;
    VaultHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        stable = new SimpleStablecoin(admin);
        vault = new Vault(usdc, stable);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));

        handler = new VaultHandler(usdc, stable, vault);

        // Restrict calls to modeled user operations so helper methods and privileged
        // token functions cannot invalidate the assumptions behind these invariants.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Ex6.2 — collateral backs all outstanding supply
    /// @dev Both tokens use 6 decimals, so raw balances are comparable. Use >= because
    ///      excess reserves do not break backing; equality is stronger than required.
    ///      This deposit/redeem campaign does not establish safety against malicious minters.
    function invariant_CollateralBacksSupply() public view {
        assertGe(vault.totalCollateral(), stable.totalSupply(), "collateral backs supply");
    }

    /// @notice Ex6.3 — the modeled mint/redeem loop leaves no sUSD in the vault
    /// @dev Deposits mint to users and redemptions burn from them, so neither operation
    ///      should accumulate sUSD here. This property relies on the handler's scope:
    ///      an unsolicited ERC20 transfer to the vault would legitimately violate it.
    function invariant_VaultHoldsNoStablecoin() public view {
        assertEq(stable.balanceOf(address(vault)), 0, "vault retains no stablecoin");
    }
}
