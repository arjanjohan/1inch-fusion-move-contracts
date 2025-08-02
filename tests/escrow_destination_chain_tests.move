#[test_only]
module fusion_plus::escrow_destination_chain_tests {
    use aptos_std::aptos_hash;
    use std::bcs;
    use std::option::{Self};
    use std::signer;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::fungible_asset::{Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use fusion_plus::escrow::{Self, Escrow};
    use fusion_plus::dutch_auction::{Self, DutchAuction};
    use fusion_plus::common;
    use fusion_plus::timelock::{Self};

    // Test amounts
    const MINT_AMOUNT: u64 = 10000000000; // 100 token
    const ASSET_AMOUNT: u64 = 100000000; // 1 token
    const SAFETY_DEPOSIT_AMOUNT: u64 = 100; // 0.000001 token

    // Test secrets and hashes
    const TEST_SECRET: vector<u8> = b"my secret";
    const WRONG_SECRET: vector<u8> = b"wrong secret";

    // Test order parameters
    const ORDER_HASH: vector<u8> = b"order_hash_123";
    const FINALITY_DURATION: u64 = 3600; // 1 hour
    const EXCLUSIVE_WITHDRAWAL_DURATION: u64 = 1800; // 30 minutes
    const PUBLIC_WITHDRAWAL_DURATION: u64 = 900; // 15 minutes
    const PRIVATE_CANCELLATION_DURATION: u64 = 900; // 15 minutes

    // Auction parameters
    const STARTING_AMOUNT: u64 = 1000000000; // 10 tokens
    const ENDING_AMOUNT: u64 = 500000000; // 5 tokens
    const AUCTION_START_TIME: u64 = 1000;
    const AUCTION_END_TIME: u64 = 2000;
    const DECAY_DURATION: u64 = 500;

    fun setup_test():
        (signer, signer, signer, signer, signer, signer, Object<Metadata>, MintRef) {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
        let fusion_signer = account::create_account_for_test(@fusion_plus);

        let account_1 = common::initialize_account_with_fa(@0x201);
        let account_2 = common::initialize_account_with_fa(@0x202);
        let account_3 = common::initialize_account_with_fa(@0x203);
        let resolver_1 = common::initialize_account_with_fa(@0x204);
        let resolver_2 = common::initialize_account_with_fa(@0x205);
        let resolver_3 = common::initialize_account_with_fa(@0x206);

        let (metadata, mint_ref) = common::create_test_token(
            &fusion_signer, b"Test Token"
        );

        // Mint assets to all accounts
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_1));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_2));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_3));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&resolver_1));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&resolver_2));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&resolver_3));

        (
            account_1,
            account_2,
            account_3,
            resolver_1,
            resolver_2,
            resolver_3,
            metadata,
            mint_ref
        )
    }

    fun create_test_hashes(num_hashes: u64): vector<vector<u8>> {
        let hashes = vector::empty<vector<u8>>();
        let i = 0;
        while (i < num_hashes) {
            let secret = vector::empty<u8>();
            vector::append(&mut secret, b"secret_");
            vector::append(&mut secret, bcs::to_bytes(&i));
            vector::push_back(&mut hashes, aptos_hash::keccak256(secret));
            i = i + 1;
        };
        hashes
    }

    fun create_resolver_whitelist(resolver: address): vector<address> {
        let whitelist = vector::empty<address>();
        vector::push_back(&mut whitelist, resolver);
        whitelist
    }

    fun create_default_auction(
        maker: &signer,
        hashes: vector<vector<u8>>,
        metadata: Object<Metadata>,
        resolver_whitelist: vector<address>
    ): Object<DutchAuction> {
        dutch_auction::new(
            maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT,
            resolver_whitelist
        )
    }

    // - - - - DESTINATION CHAIN FLOW TESTS (ETH > APT) - - - -

    #[test]
    fun test_destination_chain_full_fill_single_hash() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with single hash (no partial fills allowed)
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow with full fill (None parameter)
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow_address = object::object_address(&escrow);

        // Verify auction is deleted (completely filled)
        assert!(object::object_exists<DutchAuction>(auction_address) == false, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == STARTING_AMOUNT, 0);
        assert!(escrow::get_safety_deposit_amount(escrow) == SAFETY_DEPOSIT_AMOUNT, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance =
            primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == STARTING_AMOUNT, 0);

        let escrow_safety_deposit_balance =
            primary_fungible_store::balance(
                escrow_address, object::address_to_object<Metadata>(@0xa)
            );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_destination_chain_full_fill_multiple_hashes() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow with full fill (None parameter)
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow_address = object::object_address(&escrow);

        // Verify auction is deleted (completely filled)
        assert!(object::object_exists<DutchAuction>(auction_address) == false, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == STARTING_AMOUNT, 0);
        assert!(escrow::get_safety_deposit_amount(escrow) == SAFETY_DEPOSIT_AMOUNT, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance =
            primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == STARTING_AMOUNT, 0);

        let escrow_safety_deposit_balance =
            primary_fungible_store::balance(
                escrow_address, object::address_to_object<Metadata>(@0xa)
            );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_destination_chain_partial_fill_single_segment() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow with partial fill (segment 0)
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(0),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow_address = object::object_address(&escrow);

        // Verify auction still exists (not deleted for partial fills)
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(
            escrow::get_amount(escrow) == STARTING_AMOUNT / 10,
            0
        ); // 1/10 of total
        assert!(
            escrow::get_safety_deposit_amount(escrow) == SAFETY_DEPOSIT_AMOUNT / 10,
            0
        );
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance =
            primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == STARTING_AMOUNT / 10, 0);

        let escrow_safety_deposit_balance =
            primary_fungible_store::balance(
                escrow_address, object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT / 10,
            0
        );
    }

    #[test]
    fun test_destination_chain_partial_fill_multiple_segments() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow with partial fill (segments 0-2, so 3 segments)
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(2),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow_address = object::object_address(&escrow);

        // Verify auction still exists (not deleted for partial fills)
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(
            escrow::get_amount(escrow) == (STARTING_AMOUNT * 3) / 10,
            0
        ); // 3/10 of total
        assert!(
            escrow::get_safety_deposit_amount(escrow) == (SAFETY_DEPOSIT_AMOUNT * 3) / 10,
            0
        );
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance =
            primary_fungible_store::balance(escrow_address, metadata);
        assert!(
            escrow_main_balance == (STARTING_AMOUNT * 3) / 10,
            0
        );

        let escrow_safety_deposit_balance =
            primary_fungible_store::balance(
                escrow_address, object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            escrow_safety_deposit_balance == (SAFETY_DEPOSIT_AMOUNT * 3) / 10,
            0
        );
    }

    #[test]
    fun test_destination_chain_partial_fill_sequential() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // First partial fill: segments 0-1 (2 segments)
        let escrow1 =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(1),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(
            escrow::get_amount(escrow1) == (STARTING_AMOUNT * 2) / 10,
            0
        );
        assert!(
            escrow::get_safety_deposit_amount(escrow1)
                == (SAFETY_DEPOSIT_AMOUNT * 2) / 10,
            0
        );
        assert!(escrow::get_maker(escrow1) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow1) == false, 0);

        // Second partial fill: segments 2-4 (3 segments)
        let escrow2 =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(4),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties
        assert!(
            escrow::get_amount(escrow2) == (STARTING_AMOUNT * 3) / 10,
            0
        );
        assert!(
            escrow::get_safety_deposit_amount(escrow2)
                == (SAFETY_DEPOSIT_AMOUNT * 3) / 10,
            0
        );
        assert!(escrow::get_maker(escrow2) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow2) == false, 0);

        // Verify both escrows exist
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);

        // Verify auction still exists (not completely filled yet)
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);
    }

    #[test]
    fun test_destination_chain_partial_fill_complete_order() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Fill segments 0-8 (9 segments)
        let escrow1 =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(8),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(
            escrow::get_amount(escrow1) == (STARTING_AMOUNT * 9) / 10,
            0
        );
        assert!(
            escrow::get_safety_deposit_amount(escrow1)
                == (SAFETY_DEPOSIT_AMOUNT * 9) / 10,
            0
        );
        assert!(escrow::get_maker(escrow1) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow1) == false, 0);

        // Fill remaining segment 9 (completes the order)
        let escrow2 =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(9),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties (remaining amount)
        let remaining_amount = STARTING_AMOUNT - ((STARTING_AMOUNT * 9) / 10);
        let remaining_safety_deposit =
            SAFETY_DEPOSIT_AMOUNT - ((SAFETY_DEPOSIT_AMOUNT * 9) / 10);
        assert!(escrow::get_amount(escrow2) == remaining_amount, 0);
        assert!(
            escrow::get_safety_deposit_amount(escrow2) == remaining_safety_deposit, 0
        );
        assert!(escrow::get_maker(escrow2) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow2) == false, 0);

        // Verify both escrows exist
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);

        // Verify auction is deleted (completely filled)
        assert!(object::object_exists<DutchAuction>(auction_address) == false, 0);
    }

    #[test]
    fun test_destination_chain_withdrawal_with_segment_hash() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow with partial fill (segment 2)
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(2),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Record initial balances
        let initial_maker_balance =
            primary_fungible_store::balance(signer::address_of(&maker), metadata);
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver_1),
                object::address_to_object<Metadata>(@0xa)
            );

        // Withdraw using the secret for segment 2
        let secret_2 = vector::empty<u8>();
        vector::append(&mut secret_2, b"secret_");
        vector::append(&mut secret_2, bcs::to_bytes(&2u64));
        escrow::withdraw(&resolver_1, escrow, secret_2);

        // Verify maker received the assets (destination chain: maker gets assets)
        let final_maker_balance =
            primary_fungible_store::balance(signer::address_of(&maker), metadata);
        assert!(final_maker_balance > initial_maker_balance, 0);

        // Verify resolver received safety deposit back
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver_1),
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            final_resolver_safety_deposit_balance
                > initial_resolver_safety_deposit_balance,
            0
        );
    }

    #[test]
    fun test_destination_chain_auction_price_decay() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with single hash
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        // Test price at start of auction
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);
        let price_at_start = dutch_auction::get_current_amount(auction);
        assert!(price_at_start == STARTING_AMOUNT, 0);

        // Test price at midway point
        let midway_time = AUCTION_START_TIME + (DECAY_DURATION / 2);
        timestamp::update_global_time_for_test_secs(midway_time);
        let price_at_midway = dutch_auction::get_current_amount(auction);
        let expected_midway_price = STARTING_AMOUNT
            - ((STARTING_AMOUNT - ENDING_AMOUNT) / 2);
        assert!(price_at_midway == expected_midway_price, 0);

        // Test price at end of decay period
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + DECAY_DURATION);
        let price_at_end = dutch_auction::get_current_amount(auction);
        assert!(price_at_end == ENDING_AMOUNT, 0);

        // Create escrow at end price
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow_address = object::object_address(&escrow);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);
    }

    #[test]
    fun test_destination_chain_multiple_resolvers() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        vector::push_back(&mut resolver_whitelist, signer::address_of(&resolver_2));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // First resolver fills segments 0-2
        let escrow1 =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(2),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(
            escrow::get_amount(escrow1) == (STARTING_AMOUNT * 3) / 10,
            0
        );
        assert!(
            escrow::get_safety_deposit_amount(escrow1)
                == (SAFETY_DEPOSIT_AMOUNT * 3) / 10,
            0
        );
        assert!(escrow::get_maker(escrow1) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow1) == false, 0);

        // Second resolver fills segments 3-5
        let escrow2 =
            escrow::deploy_destination(
                &resolver_2,
                auction,
                option::some(5),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties
        assert!(
            escrow::get_amount(escrow2) == (STARTING_AMOUNT * 3) / 10,
            0
        );
        assert!(
            escrow::get_safety_deposit_amount(escrow2)
                == (SAFETY_DEPOSIT_AMOUNT * 3) / 10,
            0
        );
        assert!(escrow::get_maker(escrow2) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&resolver_2), 0);
        assert!(escrow::is_source_chain(escrow2) == false, 0);

        // Verify both escrows exist
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);

        // Verify auction still exists (not completely filled yet)
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);
    }

    // - - - - ERROR AND EDGE CASE TESTS - - - -

    #[test]
    #[expected_failure(abort_code = dutch_auction::EAUCTION_NOT_STARTED)]
    fun test_destination_chain_auction_not_started() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        // Try to fill auction before it starts
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME - 100);
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_FILL_TYPE)]
    fun test_destination_chain_invalid_segment() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with single hash (no partial fills)
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Try to fill with invalid segment (1 when max is 1)
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(1),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::ESEGMENT_ALREADY_FILLED)]
    fun test_destination_chain_segment_already_filled() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Fill segment 0
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(0),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );

        // Try to fill segment 0 again (should fail)
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(0),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_CALLER)]
    fun test_destination_chain_auction_cancellation_wrong_caller() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        // Try to cancel auction with wrong caller
        dutch_auction::cancel_auction(&resolver_1, auction);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_SECRET)]
    fun test_destination_chain_withdrawal_wrong_secret() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Try to withdraw with wrong secret
        escrow::withdraw(&resolver_1, escrow, WRONG_SECRET);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_PHASE)]
    fun test_destination_chain_withdrawal_wrong_phase() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Try to withdraw in finality phase (should fail)
        let secret_0 = vector::empty<u8>();
        vector::append(&mut secret_0, b"secret_");
        vector::append(&mut secret_0, bcs::to_bytes(&0u64));
        escrow::withdraw(&resolver_1, escrow, secret_0);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_CALLER)]
    fun test_destination_chain_withdrawal_wrong_caller() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Try to withdraw with wrong caller
        let secret_0 = vector::empty<u8>();
        vector::append(&mut secret_0, b"secret_");
        vector::append(&mut secret_0, bcs::to_bytes(&0u64));
        escrow::withdraw(&resolver_2, escrow, secret_0);
    }

    #[test]
    fun test_destination_chain_escrow_recovery_private_cancellation() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Record initial balances
        let initial_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver_1), metadata);
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver_1),
                object::address_to_object<Metadata>(@0xa)
            );

        // Fast forward to private cancellation phase
        let timelock = escrow::get_timelock(escrow);
        let (
            finality_duration, exclusive_withdrawal_duration, public_withdrawal_duration, _
        ) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration
                + exclusive_withdrawal_duration + public_withdrawal_duration + 1
        );

        // Recover escrow (only resolver can do this in private cancellation)
        escrow::recovery(&resolver_1, escrow);

        // Verify maker received the assets back
        let final_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver_1), metadata);
        assert!(
            final_resolver_balance == initial_resolver_balance + STARTING_AMOUNT,
            0
        );

        // Verify resolver received safety deposit back
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver_1),
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_CALLER)]
    fun test_destination_chain_escrow_recovery_private_cancellation_wrong_caller() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to private cancellation phase
        let timelock = escrow::get_timelock(escrow);
        let (
            finality_duration, exclusive_withdrawal_duration, public_withdrawal_duration, _
        ) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration
                + exclusive_withdrawal_duration + public_withdrawal_duration + 1
        );

        // Try to recover with wrong caller (only resolver can do this in private cancellation)
        escrow::recovery(&resolver_2, escrow);
    }

    #[test]
    fun test_destination_chain_large_amount_withdrawal() {
        let (maker, _, _, resolver_1, _, _, metadata, mint_ref) = setup_test();

        let large_amount = 1000000000000; // 1M tokens

        // Mint large amount to resolver
        common::mint_fa(&mint_ref, large_amount, signer::address_of(&resolver_1));

        // Create a Dutch auction with large amount
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction =
            dutch_auction::new(
                &maker,
                ORDER_HASH,
                hashes,
                metadata,
                large_amount,
                large_amount / 2,
                AUCTION_START_TIME,
                AUCTION_END_TIME,
                DECAY_DURATION,
                SAFETY_DEPOSIT_AMOUNT,
                resolver_whitelist
            );

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Record initial balances
        let initial_maker_balance =
            primary_fungible_store::balance(signer::address_of(&maker), metadata);

        // Withdraw large amount
        let secret_0 = vector::empty<u8>();
        vector::append(&mut secret_0, b"secret_");
        vector::append(&mut secret_0, bcs::to_bytes(&0u64));
        escrow::withdraw(&resolver_1, escrow, secret_0);

        // Verify maker received the large amount
        let final_maker_balance =
            primary_fungible_store::balance(signer::address_of(&maker), metadata);
        assert!(
            final_maker_balance == initial_maker_balance + large_amount,
            0
        );
    }

    // - - - - ADDITIONAL ERROR AND EDGE CASE TESTS - - - -

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_AUCTION_PARAMS)]
    fun test_destination_chain_invalid_auction_params_zero_amount() {
        let (maker, _, _, _, _, _, metadata, _) = setup_test();

        // Try to create auction with zero starting amount
        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&maker));
        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            0, // Invalid zero amount
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT,
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_AUCTION_PARAMS)]
    fun test_destination_chain_invalid_auction_params_start_after_end() {
        let (maker, _, _, _, _, _, metadata, _) = setup_test();

        // Try to create auction with start time after end time
        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&maker));
        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_END_TIME, // Start after end
            AUCTION_START_TIME, // End before start
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT,
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EAUCTION_ENDED)]
    fun test_destination_chain_auction_ended() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        // Try to fill auction after it ends
        timestamp::update_global_time_for_test_secs(AUCTION_END_TIME + 100);
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_HASHES)]
    fun test_destination_chain_invalid_hashes_empty() {
        let (maker, _, _, _, _, _, metadata, _) = setup_test();

        // Try to create auction with empty hashes
        let hashes = vector::empty<vector<u8>>();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&maker));
        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT,
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_SAFETY_DEPOSIT_AMOUNT)]
    fun test_destination_chain_invalid_safety_deposit_zero() {
        let (maker, _, _, _, _, _, metadata, _) = setup_test();

        // Try to create auction with zero safety deposit
        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&maker));
        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            0, // Invalid zero safety deposit
            resolver_whitelist
        );
    }

    #[test]
    fun test_destination_chain_auction_cancellation_by_maker() {
        let (maker, _, _, _, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&maker));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Maker cancels the auction
        dutch_auction::cancel_auction(&maker, auction);

        // Verify auction is deleted
        assert!(object::object_exists<DutchAuction>(auction_address) == false, 0);
    }

    #[test]
    fun test_destination_chain_auction_price_after_decay() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        // Test price after decay period (should be ENDING_AMOUNT)
        timestamp::update_global_time_for_test_secs(
            AUCTION_START_TIME + DECAY_DURATION + 100
        );
        let price_after_decay = dutch_auction::get_current_amount(auction);
        assert!(price_after_decay == ENDING_AMOUNT, 0);

        // Create escrow at end price
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify escrow amount is ENDING_AMOUNT
        assert!(escrow::get_amount(escrow) == ENDING_AMOUNT, 0);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_PHASE)]
    fun test_destination_chain_withdrawal_during_finality_phase() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Try to withdraw during finality phase (should fail)
        let secret_0 = vector::empty<u8>();
        vector::append(&mut secret_0, b"secret_");
        vector::append(&mut secret_0, bcs::to_bytes(&0u64));
        escrow::withdraw(&resolver_1, escrow, secret_0);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_PHASE)]
    fun test_destination_chain_withdrawal_during_private_cancellation_phase() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to private cancellation phase
        let timelock = escrow::get_timelock(escrow);
        let (
            finality_duration, exclusive_withdrawal_duration, public_withdrawal_duration, _
        ) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration
                + exclusive_withdrawal_duration + public_withdrawal_duration + 1
        );

        // Try to withdraw during private cancellation phase (should fail)
        let secret_0 = vector::empty<u8>();
        vector::append(&mut secret_0, b"secret_");
        vector::append(&mut secret_0, bcs::to_bytes(&0u64));
        escrow::withdraw(&resolver_1, escrow, secret_0);
    }

    #[test]
    fun test_destination_chain_escrow_recovery_public_cancellation() {
        let (maker, random_account, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Record initial balances
        let initial_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver_1), metadata);
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver_1),
                object::address_to_object<Metadata>(@0xa)
            );
        let initial_random_account_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&random_account),
                object::address_to_object<Metadata>(@0xa)
            );

        // Fast forward to public cancellation phase
        let timelock = escrow::get_timelock(escrow);
        let (
            finality_duration,
            exclusive_withdrawal_duration,
            public_withdrawal_duration,
            private_cancellation_duration
        ) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration
                + exclusive_withdrawal_duration + public_withdrawal_duration
                + private_cancellation_duration + 1
        );

        // Anyone can recover during public cancellation phase
        escrow::recovery(&random_account, escrow);

        let final_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver_1), metadata);
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver_1),
                object::address_to_object<Metadata>(@0xa)
            );
        let final_random_account_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&random_account),
                object::address_to_object<Metadata>(@0xa)
            );

        // Verify resolver received the assets back
        assert!(
            final_resolver_balance == initial_resolver_balance + STARTING_AMOUNT,
            0
        );
        // Verify resolver did not receive safety deposit back
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance,
            0
        );
        // Verify random account received safety deposit back
        assert!(
            final_random_account_safety_deposit_balance
                == initial_random_account_safety_deposit_balance
                    + SAFETY_DEPOSIT_AMOUNT,
            0
        );

    }

    #[test]
    #[expected_failure(abort_code = escrow::EOBJECT_DOES_NOT_EXIST)]
    fun test_destination_chain_withdrawal_nonexistent_escrow() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Create escrow
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Withdraw the escrow (deletes it)
        let secret_0 = vector::empty<u8>();
        vector::append(&mut secret_0, b"secret_");
        vector::append(&mut secret_0, bcs::to_bytes(&0u64));
        escrow::withdraw(&resolver_1, escrow, secret_0);

        // Try to withdraw the same escrow again (should fail)
        escrow::withdraw(&resolver_1, escrow, secret_0);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_SEGMENT)]
    fun test_destination_chain_segment_out_of_bounds() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with 5 hashes (segments 0-4)
        let hashes = create_test_hashes(5);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Try to fill with segment 5 (out of bounds)
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(5),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::ESEGMENT_ALREADY_FILLED)]
    fun test_destination_chain_multiple_resolvers_conflict() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        vector::push_back(&mut resolver_whitelist, signer::address_of(&resolver_2));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // First resolver fills segments 0-2
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(2),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );

        // Second resolver tries to fill segments 0-1 (should fail - already filled)
        escrow::deploy_destination(
            &resolver_2,
            auction,
            option::some(1),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::ESEGMENT_ALREADY_FILLED)]
    fun test_destination_chain_segment_already_filled_conflict() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        vector::push_back(&mut resolver_whitelist, signer::address_of(&resolver_2));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // First resolver fills segments 0-2
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(2),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );

        // Second resolver tries to fill segments 0-2 again (should fail)
        escrow::deploy_destination(
            &resolver_2,
            auction,
            option::some(2),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    // - - - - RESOLVER WHITELIST TESTS - - - -

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_RESOLVER)]
    fun test_destination_chain_resolver_not_in_whitelist() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with only resolver_1 in whitelist
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Try to fill auction with resolver_2 (not in whitelist) - should fail
        escrow::deploy_destination(
            &resolver_2,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_RESOLVER)]
    fun test_destination_chain_resolver_not_in_whitelist_partial_fill() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes, only resolver_1 in whitelist
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Try to fill auction with resolver_2 (not in whitelist) - should fail
        escrow::deploy_destination(
            &resolver_2,
            auction,
            option::some(0),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    fun test_destination_chain_resolver_in_whitelist_success() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with resolver_1 in whitelist
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Fill auction with resolver_1 (in whitelist) - should succeed
        let escrow =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify escrow was created successfully
        let escrow_address = object::object_address(&escrow);
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
    }

    #[test]
    fun test_destination_chain_multiple_resolvers_in_whitelist() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with both resolvers in whitelist
        let hashes = create_test_hashes(11);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_1));
        vector::push_back(&mut resolver_whitelist, signer::address_of(&resolver_2));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Both resolvers should be able to fill the auction
        let escrow1 =
            escrow::deploy_destination(
                &resolver_1,
                auction,
                option::some(2),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow2 =
            escrow::deploy_destination(
                &resolver_2,
                auction,
                option::some(5),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify both escrows were created successfully
        let escrow1_address = object::object_address(&escrow1);
        let escrow2_address = object::object_address(&escrow2);
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&resolver_2), 0);
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_RESOLVER_WHITELIST)]
    fun test_destination_chain_empty_whitelist() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with empty whitelist
        let hashes = create_test_hashes(1);
        let resolver_whitelist = vector::empty<address>();
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Try to fill auction - should fail because whitelist is empty
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_RESOLVER)]
    fun test_destination_chain_whitelist_with_wrong_resolver() {
        let (maker, _, _, resolver_1, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with resolver_2 in whitelist but try to fill with resolver_1
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_2));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Try to fill auction with resolver_1 (not in whitelist) - should fail
        escrow::deploy_destination(
            &resolver_1,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    #[test]
    fun test_destination_chain_whitelist_with_correct_resolver() {
        let (maker, _, _, _, resolver_2, _, metadata, _) = setup_test();

        // Create a Dutch auction with resolver_2 in whitelist
        let hashes = create_test_hashes(1);
        let resolver_whitelist =
            create_resolver_whitelist(signer::address_of(&resolver_2));
        let auction = create_default_auction(&maker, hashes, metadata, resolver_whitelist);

        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME);

        // Fill auction with resolver_2 (in whitelist) - should succeed
        let escrow =
            escrow::deploy_destination(
                &resolver_2,
                auction,
                option::none(),
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify escrow was created successfully
        let escrow_address = object::object_address(&escrow);
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_2), 0);
    }
}
