#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Published Anvil identities: these are used only against a local, disposable chain.
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ATTACK_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
RPC=http://127.0.0.1:8545
mkdir -p evidence
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast | tee evidence/local-deploy.txt
# Read the deployment's actual addresses instead of assuming fixed nonce/address values.
USDC=$(awk '/MockUSDC *:/ {print $NF}' evidence/local-deploy.txt)
SUSD=$(awk '/SimpleStablecoin *:/ {print $NF}' evidence/local-deploy.txt)
VAULT=$(awk '/Vault *:/ {print $NF}' evidence/local-deploy.txt)
ADMIN=$(cast wallet address --private-key "$PRIVATE_KEY")
ATTACKER=$(cast wallet address --private-key "$ATTACK_KEY")
cast send "$USDC" 'faucet(address,uint256)' "$ADMIN" 1000000000 --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$USDC" 'approve(address,uint256)' "$VAULT" 1000000000 --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$VAULT" 'deposit(uint256)' 1000000000 --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
# Ex1: exercise both directions, leaving 900 sUSD genuinely backed.
cast send "$VAULT" 'redeem(uint256)' 100000000 --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
if cast send "$SUSD" 'mint(address,uint256)' "$ATTACKER" 1000000000000 --rpc-url "$RPC" --private-key "$ATTACK_KEY" >evidence/unauthorized-mint.txt 2>&1; then
  echo 'ERROR: unauthorized mint unexpectedly succeeded' >&2
  exit 1
fi
cast send "$SUSD" 'grantRole(bytes32,address)' "$(cast keccak MINTER_ROLE)" "$ATTACKER" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
cast send "$SUSD" 'mint(address,uint256)' "$ATTACKER" 1000000000000 --rpc-url "$RPC" --private-key "$ATTACK_KEY" >/dev/null
{
  echo 'Ex3: unauthorized mint failed; granted MINTER_ROLE; unbacked mint succeeded.'
  echo "sUSD: $SUSD"
  echo "Vault: $VAULT"
  echo 'totalSupply() [6-decimal units]:'
  cast call "$SUSD" 'totalSupply()(uint256)' --rpc-url "$RPC"
  echo 'totalCollateral() [6-decimal units]:'
  cast call "$VAULT" 'totalCollateral()(uint256)' --rpc-url "$RPC"
  echo 'Expected: 1000900000000 supply versus 900000000 collateral.'
  echo 'Take a screenshot of this terminal and save evidence/ex3-screenshot.png.'
} | tee evidence/ex3-results.txt
