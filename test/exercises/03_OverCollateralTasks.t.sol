// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {MockWETH} from "../../src/exercises/MockWETH.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {OverCollateralizedVault} from "../../src/exercises/OverCollateralizedVault.sol";

/// @title Ex5 — over-collateralization + liquidation
/// @notice Validate Ex5.1–Ex5.4 with accepted and rejected positions, price shocks,
///         and capped liquidation to distinguish accounting from liquidator incentives.
/// @dev Acceptance: make exercise. A 2000e8 price means $2000 per mWETH; the 18-decimal
///      collateral and 8-decimal price require division by 1e20 for 6-decimal sUSD debt.
contract OverCollateralTasksTest is Test {
    MockWETH internal weth;
    SimpleStablecoin internal stable;
    MockPriceFeed internal feed;
    OverCollateralizedVault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant PRICE_2000 = 2000e8;

    function setUp() public {
        weth = new MockWETH();
        stable = new SimpleStablecoin(admin);
        feed = new MockPriceFeed(int256(PRICE_2000));
        vault = new OverCollateralizedVault(weth, stable, feed);

        // The vault must hold MINTER_ROLE, or both minting and burn revert
        stable.grantRole(stable.MINTER_ROLE(), address(vault));

        weth.faucet(alice, 10e18);
        weth.faucet(bob, 10e18);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        weth.approve(address(vault), amount);
        vault.depositCollateral(amount);
        vm.stopPrank();
    }

    // ==================================================================
    // Ex5.1 — decimal conversion
    // ==================================================================

    /// @dev 1e18 mWETH at a price of $2000 must equal exactly 2000e6 units of sUSD
    function test_Ex5_CollateralValue_ConvertsDecimalsCorrectly() public {
        _deposit(alice, 1e18);

        assertEq(vault.collateralValue(1e18), 2000e6, "1 mWETH @ 2000 = 2000 sUSD");
        assertEq(vault.collateralValueOf(alice), 2000e6);
        assertEq(
            vault.collateralRatio(alice),
            type(uint256).max,
            "with no debt the ratio is max"
        );
    }

    // ==================================================================
    // Ex5.2 — the floor on the collateral ratio when minting
    // ==================================================================

    function test_Ex5_Mint_HappyPath() public {
        _deposit(alice, 1e18);

        vm.prank(alice);
        vault.mintStable(1000e6);

        assertEq(stable.balanceOf(alice), 1000e6);
        assertEq(vault.debtOf(alice), 1000e6);
        assertEq(vault.collateralRatio(alice), 200, "$2000 of collateral backing 1000 sUSD = 200%");
    }

    /// @dev Collateral is worth 2000 and alice wants 1400 out → a ratio of only 142%, so it must revert
    function test_Ex5_Mint_RevertsWhenUndercollateralized() public {
        _deposit(alice, 1e18);

        vm.expectRevert(OverCollateralizedVault.Undercollateralized.selector);
        vm.prank(alice);
        vault.mintStable(1400e6);
    }

    /// @dev 1333 and 1334 whole sUSD straddle the 150% threshold at this price, checking
    ///      that truncated ratios accept 150 and reject 149. This is not a one-base-unit
    ///      boundary test: the two debts differ by 1e6 smallest units.
    function test_Ex5_Mint_ExactRatioBoundary() public {
        _deposit(alice, 1e18);
        _deposit(bob, 1e18);

        vm.prank(alice);
        vault.mintStable(1333e6); // 2000 / 1333 = 150.03% -> truncates to 150 -> passes
        assertEq(vault.collateralRatio(alice), 150);

        vm.expectRevert(OverCollateralizedVault.Undercollateralized.selector);
        vm.prank(bob);
        vault.mintStable(1334e6); // 2000 / 1334 = 149.9% -> 149 -> reverts
    }

    // ==================================================================
    // Ex5.3 — the floor on the collateral ratio when withdrawing collateral
    // ==================================================================

    /// @dev Deposit 2 mWETH (worth 4000) and mint 2000 sUSD (200%).
    ///      Withdraw 0.6 mWETH and only 1.4 mWETH is left (worth 2800) -> ratio 140% -> must revert
    function test_Ex5_Redeem_RevertsIfItBreachesRatio() public {
        _deposit(alice, 2e18);
        vm.prank(alice);
        vault.mintStable(2000e6);

        vm.expectRevert(OverCollateralizedVault.Undercollateralized.selector);
        vm.prank(alice);
        vault.redeemCollateral(0.6e18);
    }

    /// @dev Withdraw 0.5 mWETH and 1.5 mWETH is left (worth 3000) -> exactly 150% -> passes
    function test_Ex5_Redeem_AtExactRatioSucceeds() public {
        _deposit(alice, 2e18);
        vm.prank(alice);
        vault.mintStable(2000e6);

        vm.prank(alice);
        vault.redeemCollateral(0.5e18);

        assertEq(vault.collateralOf(alice), 1.5e18);
        assertEq(vault.collateralRatio(alice), 150);
    }

    // ==================================================================
    // Ex5.4 — liquidation
    // ==================================================================

    /// @dev Price falls from 2000 to 1100: the collateral is worth only 1100 against a debt of
    ///      1000 -> ratio 110% < 120%
    ///      bob burns all of alice's debt and takes $1100 worth of mWETH (including the 10% bonus)
    ///      = 1100 / 1100 = exactly 1 mWETH
    function test_Ex5_Liquidate_SeizesCollateral() public {
        _deposit(alice, 1e18);
        vm.prank(alice);
        vault.mintStable(1000e6);

        // alice sells her sUSD to bob in the open market, but her debt does not disappear with it
        vm.prank(alice);
        stable.transfer(bob, 1000e6);

        feed.setPrice(1100e8);
        assertEq(vault.collateralRatio(alice), 110, "liquidatable only once it falls to 110%");

        vm.prank(bob);
        vault.liquidate(alice);

        assertEq(stable.balanceOf(bob), 0, "all of bob's sUSD is burned");
        assertEq(stable.totalSupply(), 0, "no sUSD is left in circulation once the debt is cleared");
        assertEq(vault.debtOf(alice), 0);
        assertEq(vault.collateralOf(alice), 0, "alice's collateral is taken in full");
        assertEq(weth.balanceOf(bob), 11e18, "10 held from the start + 1 seized in liquidation");
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    /// @dev A ratio of 200% is a healthy position and must not be liquidatable
    function test_Ex5_Liquidate_RevertsWhenHealthy() public {
        _deposit(alice, 1e18);
        vm.prank(alice);
        vault.mintStable(1000e6);

        vm.expectRevert(OverCollateralizedVault.NotLiquidatable.selector);
        vm.prank(bob);
        vault.liquidate(alice);
    }

    /// @dev At 100% backing, the collateral covers principal but not the 10% bonus.
    ///      Capping seizure avoids overdrawing the position while the full debt is burned.
    ///      Thus this test demonstrates lost liquidator compensation, not residual debt;
    ///      a rational liquidator may decline a similarly unattractive transaction.
    function test_Ex5_Liquidate_CapsSeizureAtAvailableCollateral() public {
        _deposit(alice, 1e18);
        vm.prank(alice);
        vault.mintStable(1000e6);
        vm.prank(alice);
        stable.transfer(bob, 1000e6);

        feed.setPrice(1000e8); // collateral worth 1000 against a debt of 1000 -> 100%
        vm.prank(bob);
        vault.liquidate(alice);

        assertEq(vault.collateralOf(alice), 0);
        assertEq(weth.balanceOf(bob), 11e18, "all 1 mWETH is taken; the bonus is not fully covered");
        assertEq(stable.totalSupply(), 0);
    }

    // ==================================================================
    // Fuzz property: maximum permitted minting stays backed at the fixed mock price.
    // Later price shocks and privileged issuance are outside this test's operation sequence.
    // ==================================================================

    function testFuzz_Ex5_SupplyBackedByValue(uint96 raw) public {
        uint256 deposit = bound(uint256(raw), 1, 100e18);

        weth.faucet(alice, deposit);
        _deposit(alice, deposit);

        uint256 maxMint =
            vault.collateralValue(deposit) * vault.RATIO_PRECISION() / vault.MIN_COLLATERAL_RATIO();

        if (maxMint > 0) {
            vm.prank(alice);
            vault.mintStable(maxMint);
        }

        assertLe(
            stable.totalSupply(),
            vault.collateralValue(weth.balanceOf(address(vault))),
            "sUSD supply must not exceed the value of the collateral held in the vault"
        );
    }
}
