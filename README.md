# Cross-Chain Atomic Swap Protocol

![Logo](assets/logo.png)

A secure cross-chain atomic swap protocol built on Aptos that enables trustless asset swaps across different blockchains. This is the Aptos implementation of the [1inch Fusion Plus](https://github.com/1inch/cross-chain-swap) protocol.

## Overview

The protocol enables secure cross-chain swaps through a clean separation of concerns with hashlocked and timelocked escrows. It consists of several key components that work together to provide a secure, trustless cross-chain swap experience.

### Core Components

1. **Fusion Orders (`fusion_order.move`)**
   - User-created orders that can be cancelled before pickup
   - Includes safety deposit requirements
   - Order cancellation by owner
   - Friend function for converting to escrow

2. **Escrow (`escrow.move`)**
   - Secure asset escrow with timelock and hashlock protection
   - Two creation methods: from fusion order or directly from resolver
   - Timelock-based phase management
   - Hashlock-based secret verification
   - Asset withdrawal and cancellation logic
   - Source chain and destination chain handling

3. **Resolver Registry (`resolver_registry.move`)**
   - Resolver registration and status management
   - Admin functions for resolver management

4. **Timelock (`timelock.move`)**
   - Phase management for escrow lifecycle
   - Configurable duration validation
   - Phase transition logic
   - Individual phase duration validation

5. **Hashlock (`hashlock.move`)**
   - Secret verification for asset withdrawal
   - Hash-based security mechanism

6. **Constants (`libs/constants.move`)**
   - Protocol-wide configuration
   - Safety deposit settings
   - Timelock duration defaults

### Architecture Flow

```
[SOURCE CHAIN]                       [DESTINATION CHAIN]

User creates Fusion Order
         ↓
   [Can be cancelled by user]
         ↓
Resolver picks up order           Resolver creates escrow
         ↓                                   ↓
   Fusion Order → Escrow                Escrow
                     ↓                     ↓
                    [Timelock phases begin]
                                 ↓
                    [Hashlock protection active]
                                 ↓
                    [Withdrawal or Recovery]
```

### Timelock Phases

![Timelocks](assets/timelocks.png)

1. **Finality Phase**
   - Initial period where settings can be modified
   - Recipient can be set or updated
   - No withdrawals allowed

2. **Exclusive Phase**
   - Only intended recipient can claim assets
   - Requires valid secret for withdrawal
   - Hashlock verification required

3. **Private Cancellation Phase**
   - Owner can cancel and reclaim assets
   - Requires no prior withdrawal
   - Admin-only recovery

4. **Public Cancellation Phase**
   - Anyone with the correct secret can claim
   - Anyone can cancel if not claimed
   - Public recovery available

## Project Structure

```
aptos-contracts/
├── sources/                   # Move smart contracts
│   ├── fusion_order.move      # Order creation and management
│   ├── escrow.move            # Hashed timelocked Escrow logic
│   ├── resolver_registry.move # Resolver management
│   ├── timelock.move          # Timelock management
│   ├── hashlock.move          # Hashlock verification
│   └── libs/
│       └── constants.move     # Protocol constants
├── tests/                     # Tests
│   ├── fusion_order_tests.move
│   ├── escrow_tests.move
│   ├── resolver_registry_tests.move
│   ├── timelock_tests.move
│   ├── hashlock_tests.move
│   └── helpers/
│       └── common.move        # Test utilities
└── Move.toml                  # Project configuration
```


## Requirements

Before you begin, you need to install the following tools:

- [Aptos CLI](https://aptos.dev/tools/aptos-cli/)
- [Move Prover](https://aptos.dev/tools/install-move-prover/)

## Quickstart

1. Build the project:
```bash
aptos move compile
```

2. Run tests:
```bash
aptos move test
```

3. Deploy the contracts:
```bash
aptos move publish --named-addresses fusion_plus=YOUR_ACCOUNT_ADDRESS
```

## Usage

<!-- TODO: Replace this with user friendly scripts -->

## TODO

- Local testing
- Frontend
- Partial fills

## Hackathon bounties

### Extend Fusion+ to Aptos

This submission is an implementation of 1inch Fusion+ built with Aptos Move. One of the main differences between Move and EVM is that everything in Move is owned, unlike EVM where contracts can transfer user funds with prior approval. This means that the resolver cannot directly transfer the user's funds to the escrow on behalf of the user.

I solved this ownership challenge by implementing a two-step process: users first deposit funds into the `fusion_order.move` module, which stores the funds in an object that only the user and the Escow module can interact with. The resolver can then withdraw with these pre-deposited funds when creating the escrow (in `escrow.move`). This maintains Move's security model while enabling the Fusion+ workflow.

Until the resolver picks up the order, the user retains full control and can withdraw their funds from the `fusion_order` at any time, effectively cancelling their order. This provides users with the same flexibility as the EVM version while respecting Move's ownership principles.

Besides this, my implementation closely follows the EVM version's architecture, with everything divided into separate modules for clarity and readability: `fusion_order.move` handles order creation on maker side, `escrow.move` manages asset with a timelock and hashlock and `resolver_registry.move` manages the whitelisted resolvers.

- [Deployed smart contracts]()

### Extend Fusion+ to Any Other Chain
Since Movement uses the same smart contract language, I also deployed the contracts to Movement Network.

- [Deployed smart contracts]()

## Team

Built during the 1inch & ETHGlobal Unite DeFi hackathon by:

<div>
  <img src="assets/milady.jpg" alt="Logo" width="120" height="120" style="border-radius: 50%; object-fit: cover; ">

  - [arjanjohan](https://x.com/arjanjohan/)
</div>

