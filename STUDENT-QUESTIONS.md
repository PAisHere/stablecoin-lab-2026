# STUDENT-QUESTIONS.md — Discussion questions (submit with your repo)

Answer directly under each question. 150–300 words each — **reasoning over length**.

---

## A. Permission design

**A1.** The vault holds `MINTER_ROLE`, so it can `burn` any user's balance. Explain why that is a risk, then write out how you would change `Vault` and `SimpleStablecoin` to remove it.

> Your answer:

MINTER_ROLE permits burn(from, amount) for any holder without consent. The token therefore gives Vault broader authority than redemption needs. Nevertheless, today's Vault.redeem burns only msg.sender's tokens: impersonating Vault in a test proves token-level authority, not an externally reachable arbitrary-burn exploit. I would remove the role-only burn function and implement burnFrom(owner, amount) that consumes an allowance. Vault.redeem would call burnFrom(msg.sender, amount), then pay collateral; holders would first approve the vault. Minting would remain separately restricted. Tests should cover absent allowance, insufficient allowance, authorized redemption, and atomic rollback when payment fails. This preserves redemption while preventing the vault identity from confiscating balances without authorization.

**A2.** In this contract `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE` and `PAUSER_ROLE` all go to the same address. How would you split them in production, and who holds each?

> Your answer:

I would assign DEFAULT_ADMIN_ROLE to an independently controlled governance multisignature with a timelock for role changes. MINTER_ROLE should belong to audited collateral vaults, rather than ordinary operator wallets. After granting the vault its role and transferring administration, the deployer should relinquish unnecessary privileges. A separate security multisignature would hold PAUSER_ROLE for rapid incident response, with a reviewed recovery process for unpausing. Monitoring should flag unexpected issuance and role grants. Separation limits the damage from one operational key's compromise, but governance remains trusted because an administrator can appoint another minter. Signer independence, transparent changes, and minimal privileges matter more than merely using three differently named addresses.

---

## B. Pausing and redemption

**B1.** `_update` is the single entry point for every balance change, so `pause()` freezes transfers, minting and redemption together. If you wanted "pause transfers but **allow redemption**", how would you change it? Give the approach — full code not required.

> Your answer:

I would replace the universal whenNotPaused check on _update with separate transfer, issuance, and redemption policies. Two nonzero endpoints identify an ordinary transfer; from == address(0) identifies minting; to == address(0) identifies burning. A transfer pause should reject ordinary transfers while permitting authorized redemption burns. Issuance can have its own pause flag. Vault.redeem and the collateral token must also remain operational; permitting burns alone does not guarantee payment. Tests should prove that paused transfers fail, permitted redemptions succeed, and failed collateral payments roll back burns. An emergency redemption stop may still be appropriate for a reserve-draining exploit, but its purpose and authority should be explicitly defined.

**B2.** In 2008, when a money-market fund "broke the buck", redemptions were frozen for days. In 2023 USDC depegged to $0.87 after a reserve bank failed, but redemptions were **not** shut. Compare the two responses — what does closing the redemption channel, or leaving it open, do to a stablecoin?

> Your answer:

In 2008 the Reserve Primary Fund reported a 97-cent net asset value and suspended redemption payments, followed by regulatory permission for a longer suspension. Closing the exit can avoid destructive forced sales but increases uncertainty and secondary-market discounts. In March 2023 Circle maintained its one-for-one USDC redemption commitment; bank settlement nevertheless depended on banking hours, and requests accumulated before Monday processing resumed. An open, credible redemption channel encourages arbitrageurs to buy discounted coins and redeem at par. Recovery also depended on reserve access and government action, not only redemption policy. Neither keeping redemption open nor freezing it creates missing assets; the tradeoff combines solvency, liquidity, settlement delays, and equitable treatment of holders.

---

## C. Depeg analysis

**C1.** Under what conditions does this coin depeg? Distinguish at least two classes of cause, and say how each one shows up in the invariant `totalCollateral() >= totalSupply()`.

> Your answer:

A balance-sheet shortfall occurs when a privileged minter issues unsupported sUSD: supply rises without collateral, so totalCollateral() >= totalSupply() fails immediately. Falling WETH prices can similarly undermine value backing in Ex5, even without changing token quantities. A second cause is blocked convertibility. Pausing burns prevents redemption while the original accounting invariant can remain true; holders may price the resulting delay and uncertainty at a discount. A third cause is collateral devaluation or transfer restrictions. Equal USDC and sUSD token counts do not prove dollar backing if USDC itself loses value. The invariant therefore checks accounting under assumptions, not complete market-price stability. Value, liquidity, redemption access, and privileged roles require separate assessment.

**C2.** Suppose an attacker bribes their way to `MINTER_ROLE`, mints 1,000,000 sUSD out of nothing and redeems it all. Describe the flow of funds, and name the step that could have stopped them.

> Your answer:

The attacker receives MINTER_ROLE, mints 1_000_000e6 sUSD without depositing collateral, then calls redeem. Vault burns the attacker's coins and pays collateral from honest users' reserves. Full redemption succeeds only if at least one million collateral tokens are available; otherwise the request reverts and the attacker can drain smaller amounts up to the reserve balance. Remaining unsupported supply harms later redeemers. The decisive prevention point is the role grant: independently approved governance changes and removing unrestricted external minters prevent authority from reaching the attacker. Constraining issuance to collateral-backed contract logic also prevents unsupported minting. Invariant monitoring can detect the shortfall, but intervention after issuance is weaker than preventing it before reserves leave.

---

## D. Toward RWA

**D1.** Right now the collateral is `MockUSDC` and `totalCollateral()` just reads an on-chain balance — simple and reliable. If the collateral were **US Treasuries**, could this invariant still be written that way? What new problems appear?

> Your answer:

A Treasury-token balance counts claims, not independently verified underlying securities. Solidity cannot establish off-chain ownership, custody, encumbrances, or settlement availability. I would compare conservatively valued, legally available reserves net of liabilities against outstanding dollar claims, using consistent units, valuation timestamps, and haircuts. Attestations and reconciliations support the ownership claim but are delayed evidence. A separate liquidity measure should estimate cash available within the redemption window: a solvent portfolio can still face settlement delays or losses from forced sales after rate changes. Custodian failure, double pledging, and stale data remain risks. A contract can reject stale reports and enforce rules, but cannot make an unreliable custodian or unenforceable legal claim reliable.

**D2.** If the collateral were **a building**, how would you put it inside this vault? Which off-chain roles or legal structures would you have to introduce?

> Your answer:

A property-owning entity could issue tokens representing clearly defined ownership or economic claims. The vault would hold those tokens or an enforceable security interest; legal documents would specify transfer rights, income distribution, foreclosure, and insolvency treatment. Moving a token does not itself establish land-title transfer. The arrangement needs jurisdiction-specific legal advice, property management, valuation, insurance, and appropriate registry, custody, compliance, and audit functions. Buildings require conservative lending limits because appraisals are infrequent, expenses reduce net value, and liquidation can take months. A liquid reserve and disclosed redemption queues may be necessary. Oracle reports convey valuations but cannot guarantee immediate cash realization. Tokenization improves claim recording without removing disputes, management failure, or underlying illiquidity.

---

## E. Tests (Tier 1 required — this is Ex4)

Turn the red tests green in `test/exercises/01_LoopTasks.t.sol` to cover the scenarios below, and write your test function names here:

| Scenario | Your test function name |
|---|---|
| Minting by a non-minter reverts | `test_Ex4_Mint_RevertsForNonMinter` |
| Transfers revert while paused | `test_Ex4_Pause_BlocksTransfers` |
| **Redemption** reverts while paused | `test_Ex4_Pause_BlocksRedeem` |
| An attacker cannot burn someone else's balance | `test_Ex4_AttackerCannotBurnOthersBalance` |
| ...but the vault holding `MINTER_ROLE` can | `test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance` |

That last pair is meant to be read together: the guard is written correctly, but the key was handed to the vault. Keep it in mind when you answer A1.

Now write one more scenario you consider **most likely to be attacked**, and say why you picked it:

> Your answer:

The scenario I would prioritize is administrator compromise followed by granting an attacker MINTER_ROLE, unbacked minting, and reserve-draining redemption. It bypasses the correctly implemented non-minter guard through a legitimate role grant. A reproducible test should deposit honest users' collateral, grant the role as admin, mint to the attacker, redeem up to the available collateral, and assert that remaining supply exceeds remaining reserves. Ex3 demonstrates the issuance stage; the drain stage explains the harm to honest holders. This is a threat-model priority based on the concentration of authority, not a measured claim about attack frequency.

## References for B2

- SEC, Reserve Fund FAQ: https://www.sec.gov/divisions/investment/guidance/reservefundmmffaq.htm
- Circle, reserve availability and 1:1 redemption commitment: https://www.circle.com/pressroom/3-3-billion-of-usdc-reserve-risk-removed-dollar-de-peg-closes
- Circle, March 15 operational update: https://www.circle.com/blog/march-15-update-on-usdc-operations

