# Move United - Cross-Chain Atomic Swap Protocol

![Logo](assets/new_logo.png)

Move United is a comprehensive cross-chain swap protocol that enables secure asset transfers between any EVM and Aptos blockchain. The protocol uses a combination of hashlock/timelock mechanisms and Dutch auctions to ensure atomic cross-chain swaps. This is the Aptos implementation of the [1inch Fusion Plus](https://github.com/1inch/cross-chain-swap) protocol.

For the E2E tests between Ethereum Mainnet Fork and Aptos Testnet, please see the [1inch-fusion-move-resolver](https://github.com/arjanjohan/1inch-fusion-move-resolver) repo.

### Core Components

#### **Router Module** (`router.move`)
Central entry point for all user-facing operations:
- `create_auction` - Create Dutch auctions for ETH → APT orders
- `cancel_auction` - Cancel Dutch auctions
- `create_fusion_order` - Create fusion orders for APT → ETH orders
- `cancel_fusion_order` - Cancel fusion orders
- `deploy_source_single_fill` - Deploy source escrow for full fills
- `deploy_source_partial_fill` - Deploy source escrow for partial fills
- `deploy_destination_single_fill` - Deploy destination escrow from auction
- `deploy_destination_partial_fill` - Deploy destination escrow for partial fills
- `escrow_withdraw` - Withdraw from escrow using secret
- `escrow_recovery` - Recover escrow during cancellation phases

#### **Dutch Auction Module** (`dutch_auction.move`)
Manages price discovery for ETH → APT orders:
- Dynamic pricing with decay over time
- Support for partial fills with multiple segments
- Handles asset and safety deposit withdrawals from Resolver to `escrow.move` module
- Segment-based fill tracking
- Resolver whitelist support

#### **Fusion Order Module** (`fusion_order.move`)
Handles APT → ETH order creation and management:
- Order creation with resolver whitelist
- Partial fill support with segment tracking
- Asset escrow and safety deposit management
- Multiple secret support for partial fills
- Can be cancelled at any time by user
- Option to allow resolver to cancel/recover stale orders

#### **Escrow Module** (`escrow.move`)
Core escrow functionality for both chains:
- Source and destination escrow deployment
- Timelock and hashlock integration
- Withdrawal and recovery mechanisms
- Cross-chain secret verification
- Support for both single and partial fills

#### **Hashlock Module** (`hashlock.move`)
Cryptographic secret management:
- Hash creation and verification
- Merkle tree support for multiple secrets
- Secret validation and security
- Support for segment-based secrets

#### **Timelock Module** (`timelock.move`)
Time-based phase management:
- Finality, exclusive, and cancellation phases
- Phase validation and duration tracking
- Public and private cancellation periods
- Configurable duration parameters

### Architecture Flow

The protocol supports two distinct cross-chain swap flows:

#### **ETH → APT Flow (Dutch Auction)**
```
[ETHEREUM]                                    [APTOS]

User submits order                    User initiates Dutch auction
         ↓                                       ↓
         ↓                             [Price decays over time]
         ↓                                       ↓
Resolver picks up order                  Resolver fills auction
         ↓                                       ↓
   Source Escrow                          Destination Escrow
         ↓                                       ↓
   [Timelock phases begin]               [Timelock phases begin]
         ↓                                       ↓
   [Hashlock protection active]          [Hashlock protection active]
         ↓                                       ↓
   [Withdrawal or Recovery]              [Withdrawal or Recovery]
```

#### **APT → ETH Flow (Fusion Order)**
```
[APTOS]                                    [ETHEREUM]

User creates Fusion Order                Dutch auction initiated on EVM
         ↓                                       ↓
   [Can be cancelled by user]           [Price decays over time]
         ↓                                       ↓
Resolver picks up order                   Resolver fills auction
         ↓                                       ↓
   Source Escrow                          Destination Escrow
         ↓                                       ↓
   [Timelock phases begin]               [Timelock phases begin]
         ↓                                       ↓
   [Hashlock protection active]           [Hashlock protection active]
         ↓                                       ↓
   [Withdrawal or Recovery]              [Withdrawal or Recovery]
```

### Timelock Phases

![Timelocks](assets/timelocks.png)

1. **Finality Phase**
   - Initial period where settings can be modified
   - Recipient can be set or updated
   - No withdrawals allowed
   - Duration: `finality_duration`

2. **Exclusive Phase**
   - Only intended recipient can claim assets
   - Requires valid secret for withdrawal
   - Hashlock verification required
   - Duration: `exclusive_duration`

3. **Private Cancellation Phase**
   - Owner can cancel and reclaim assets
   - Requires no prior withdrawal
   - Admin-only recovery
   - Duration: `private_cancellation_duration`

4. **Public Cancellation Phase**
   - Anyone with the correct secret can claim
   - Anyone can cancel if not claimed
   - Public recovery available
   - Duration: Remaining time until auction end

## Project Structure

```
aptos-contracts/
├── sources/                   # Move smart contracts
│   ├── router.move            # Central entry point for all operations
│   ├── dutch_auction.move     # Dutch auction for ETH → APT orders
│   ├── fusion_order.move      # Order creation for APT → ETH orders
│   ├── escrow.move            # Hashed timelocked Escrow logic
│   ├── timelock.move          # Timelock management
│   ├── hashlock.move          # Hashlock verification
│   └── libs/
│       └── constants.move     # Protocol constants
├── tests/                     # Tests
│   ├── dutch_auction_tests.move
│   ├── fusion_order_tests.move
│   ├── escrow_tests.move
│   ├── timelock_tests.move
│   ├── hashlock_tests.move
│   └── helpers/
│       └── common.move        # Test utilities
└── Move.toml                  # Project configuration
```

## Requirements

Before you begin, you need to install the following tools:

- [Aptos CLI](https://aptos.dev/tools/aptos-cli/)

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

### Basic Integration

The Move United protocol can be integrated into your applications in several ways:

#### 1. Direct Contract Interaction

```move
// Example: Creating a Dutch auction for ETH → APT swap
let auction_id = router::create_auction(
    &mut account,
    initial_price,
    final_price,
    duration_seconds,
    asset_amount,
    safety_deposit
);
```

#### 2. Fusion Order Creation

```move
// Example: Creating a Fusion order for APT → ETH swap
let order_id = router::create_fusion_order(
    &mut account,
    asset_amount,
    safety_deposit,
    resolver_whitelist,
    stale_timestamp
);
```

#### 3. Escrow Operations

```move
// Example: Withdrawing from escrow using secret
router::escrow_withdraw(
    &mut account,
    escrow_id,
    secret
);
```

### Move tests.
Summary of the Move tests:
```
Test result: OK. Total tests: 146; passed: 146; failed: 0
Warning: unknown field name found. Expected one of [package, build, addresses, dev-addresses, dependencies, dev-dependencies], but found 'profile'
+-------------------------+
| Move Coverage Summary   |
+-------------------------+
Module 0000000000000000000000000000000000000000000000000000000000000123::hashlock
>>> % Module coverage: 100.00
Module 0000000000000000000000000000000000000000000000000000000000000123::dutch_auction
>>> % Module coverage: 92.82
Module 0000000000000000000000000000000000000000000000000000000000000123::timelock
>>> % Module coverage: 100.00
Module 0000000000000000000000000000000000000000000000000000000000000123::fusion_order
>>> % Module coverage: 94.82
Module 0000000000000000000000000000000000000000000000000000000000000123::escrow
>>> % Module coverage: 93.95
Module 0000000000000000000000000000000000000000000000000000000000000123::router
>>> % Module coverage: 0.00
+-------------------------+
| % Move Coverage: 91.66  |
+-------------------------+
Please use `aptos move coverage -h` for more detailed source or bytecode test coverage of this package
{
  "Result": "Success"
}
```

### End-to-End Testing

For comprehensive testing between Ethereum and Aptos networks, refer to the [resolver repository](https://github.com/arjanjohan/1inch-fusion-move-resolver) which includes:

- **Complete E2E test suite**: [main.spec.ts](https://github.com/arjanjohan/1inch-fusion-move-resolver/blob/master/tests/main.spec.ts)
- **Setup instructions**: [README.md](https://github.com/arjanjohan/1inch-fusion-move-resolver/blob/master/README.md)
- **Local Ethereum fork integration** with Aptos testnet
- **Cross-chain transaction verification**

## Next Steps

The Move United implementation is complete with all core Fusion+ functionality, including hash and timelock mechanisms, partial fills, Dutch auctions, and escrow with withdrawal and recovery mechanisms. However, several enhancements are planned for development after this hackathon:

- **Frontend integration** - Aptos needs to be integrated in the 1inch frontend, during the hackathon I focussed on the core contracts and I did not prioritize making a frontend.
- **Sponsored Transactions** - This is a feature on Aptos that can be added to allow for a gasless experience. More details [here](https://aptos.dev/build/guides/sponsored-transactions).
- **1inch SDK Integration** - Currently the 1inch SDK does not support Aptos. I had a look at the SDK, and integrating a completely new non-EVM chain in this SDK was out of scope for me during this hackathon. But it's probably the most important item to build after the hackathon!

## Hackathon bounties

### Extend Fusion+ to Aptos

This submission is an implementation of 1inch Fusion+ built with Aptos Move. One of the main differences between Move and EVM is that everything in Move is owned, unlike EVM where contracts can transfer user funds with prior approval. This means that the resolver cannot directly transfer the user's funds to the escrow on behalf of the user.

I solved this ownership challenge by implementing a two-step process: users first deposit funds via the `fusion_order.move` module into a `FusionOrder` object, that only the user and the `Escrow` module can interact with. The resolver can then withdraw with these pre-deposited funds when creating the escrow (only via the `Escrow` module). This maintains Move's security model while enabling the Fusion+ workflow.

Until the resolver picks up the order, the user retains full control and can withdraw their funds from the `FusionOrder` at any time, effectively cancelling their order. This provides users with the same flexibility as the EVM version while respecting Move's ownership principles. Optionally, a user can allow a resolver to cancel a stale `FusionOrder` on his behalf by defining a timestamp. This will cost the user his safety deposit, but ensures his stale order will be returned to him after the timestamp.

Besides this, my implementation closely follows the EVM version's architecture, with everything divided into separate modules for clarity and readability: `fusion_order.move` handles order creation on source chain, `escrow.move` manages asset with a timelock and hashlock, and `dutch_auction.move` manages price discovery for destination chain.

- [Deployed smart contracts on Aptos Testnet](https://explorer.aptoslabs.com/account/0x0e6067afa8c1ca1b0cc486ec2a33ef65c3d8678b67ce9f1e4995fddae63cd25b/modules/packages/fusion_plus?network=testnet)
- [Resolver transactions on Aptos Testnet](https://explorer.aptoslabs.com/account/0x55bb788452c5b9489c13c39a67e3588b068b4ae69141de7d250aa0c6b1160842?network=testnet)
- [EVM transactions on Tenderly](https://virtual.mainnet.eu.rpc.tenderly.co/7a11fb86-a4e6-4390-8fdd-d5e99903eb5d)

### Extend Fusion+ to Any Other Chain
Since Movement uses the same smart contract language (although a differnt version), I also deployed the contracts to Movement Network. In [a separate branch](https://github.com/arjanjohan/1inch-fusion-move-contracts/tree/movement) the store the Movement specific `Move.toml` changes and some syntax modifications to work with the older Move 1 language version..

- [Deployed smart contracts on Movement Testnet](https://explorer.movementnetwork.xyz/account/0x0e6067afa8c1ca1b0cc486ec2a33ef65c3d8678b67ce9f1e4995fddae63cd25b/modules/packages/fusion_plus?network=bardock+testnet)
- [Resolver transactions on Movement Testnet](https://explorer.movementnetwork.xyz/account/0x55bb788452c5b9489c13c39a67e3588b068b4ae69141de7d250aa0c6b1160842?network=bardock+testnet)

## Team

Built during the 1inch & ETHGlobal Unite DeFi hackathon by:

<div>
  <img src="assets/milady.jpg" alt="Logo" width="120" height="120" style="border-radius: 50%; object-fit: cover; ">

  - [arjanjohan](https://x.com/arjanjohan/)
</div>

