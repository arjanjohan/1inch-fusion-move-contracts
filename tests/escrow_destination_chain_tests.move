#[test_only]
module fusion_plus::escrow_destination_chain_tests {
    use aptos_std::aptos_hash;
    use std::bcs;
    use std::option::{Self, Option};
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
    use fusion_plus::hashlock::{Self};

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
    const EXCLUSIVE_DURATION: u64 = 1800; // 30 minutes
    const PRIVATE_CANCELLATION_DURATION: u64 = 900; // 15 minutes

    // Auction parameters
    const STARTING_AMOUNT: u64 = 1000000000; // 10 tokens
    const ENDING_AMOUNT: u64 = 500000000; // 5 tokens
    const AUCTION_START_TIME: u64 = 1000;
    const AUCTION_END_TIME: u64 = 2000;
    const DECAY_DURATION: u64 = 500;

    fun setup_test(): (signer, signer, signer, signer, signer, signer, Object<Metadata>, MintRef) {
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

        (account_1, account_2, account_3, resolver_1, resolver_2, resolver_3, metadata, mint_ref)
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


    // - - - - DESTINATION CHAIN FLOW TESTS (ETH > APT) - - - -

    #[test]
    fun test_destination_chain_full_fill_single_hash() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with single hash (no partial fills allowed)
        let hashes = create_test_hashes(1);
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // Create escrow with full fill (None parameter)
        let escrow = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
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
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance > 0, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_destination_chain_full_fill_multiple_hashes() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // Create escrow with full fill (None parameter)
        let escrow = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
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
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance > 0, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_destination_chain_partial_fill_single_segment() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // Create escrow with partial fill (segment 0)
        let escrow = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(0),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
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
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance > 0, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance > 0, 0);
    }

    #[test]
    fun test_destination_chain_partial_fill_multiple_segments() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // Create escrow with partial fill (segments 0-2, so 3 segments)
        let escrow = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(2),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
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
        assert!(escrow::get_maker(escrow) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == false, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance > 0, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance > 0, 0);
    }

    #[test]
    fun test_destination_chain_partial_fill_sequential() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // First partial fill: segments 0-1 (2 segments)
        let escrow1 = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(1),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(escrow::get_maker(escrow1) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow1) == false, 0);

        // Second partial fill: segments 2-4 (3 segments)
        let escrow2 = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(4),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties
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
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        let auction_address = object::object_address(&auction);

        // Verify auction exists
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // Fill segments 0-8 (9 segments)
        let escrow1 = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(8),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(escrow::get_maker(escrow1) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow1) == false, 0);

        // Fill remaining segment 9 (completes the order)
        let escrow2 = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(9),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties
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
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // Create escrow with partial fill (segment 2)
        let escrow = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(2),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Record initial balances
        let initial_maker_balance = primary_fungible_store::balance(signer::address_of(&maker), metadata);
        let initial_resolver_safety_deposit_balance = primary_fungible_store::balance(
            signer::address_of(&resolver_1), object::address_to_object<Metadata>(@0xa)
        );

        // Withdraw using the secret for segment 2
        let secret_2 = vector::empty<u8>();
        vector::append(&mut secret_2, b"secret_");
        vector::append(&mut secret_2, bcs::to_bytes(&2u64));
        escrow::withdraw(&resolver_1, escrow, secret_2);

        // Verify maker received the assets (destination chain: maker gets assets)
        let final_maker_balance = primary_fungible_store::balance(signer::address_of(&maker), metadata);
        assert!(final_maker_balance > initial_maker_balance, 0);

        // Verify resolver received safety deposit back
        let final_resolver_safety_deposit_balance = primary_fungible_store::balance(
            signer::address_of(&resolver_1), object::address_to_object<Metadata>(@0xa)
        );
        assert!(final_resolver_safety_deposit_balance > initial_resolver_safety_deposit_balance, 0);
    }

    #[test]
    fun test_destination_chain_auction_price_decay() {
        let (maker, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a Dutch auction with single hash
        let hashes = create_test_hashes(1);
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        // Test price at start of auction
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 50);
        let price_at_start = dutch_auction::get_current_amount(auction);
        assert!(price_at_start < STARTING_AMOUNT, 0);
        assert!(price_at_start > ENDING_AMOUNT, 0);

        // Test price at end of decay period
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + DECAY_DURATION + 100);
        let price_at_end = dutch_auction::get_current_amount(auction);
        assert!(price_at_end == ENDING_AMOUNT, 0);

        // Create escrow at end price
        let escrow = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::none(),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
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
        let auction = dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT
        );

        let auction_address = object::object_address(&auction);

        // Set time to auction start
        timestamp::update_global_time_for_test_secs(AUCTION_START_TIME + 100);

        // First resolver fills segments 0-2
        let escrow1 = escrow::deploy_destination(
            &resolver_1,
            auction,
            option::some(2),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(escrow::get_maker(escrow1) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow1) == false, 0);

        // Second resolver fills segments 3-5
        let escrow2 = escrow::deploy_destination(
            &resolver_2,
            auction,
            option::some(5),
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties
        assert!(escrow::get_maker(escrow2) == signer::address_of(&maker), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&resolver_2), 0);
        assert!(escrow::is_source_chain(escrow2) == false, 0);

        // Verify both escrows exist
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);

        // Verify auction still exists (not completely filled yet)
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);
    }

}