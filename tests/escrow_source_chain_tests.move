#[test_only]
module fusion_plus::escrow_source_chain_tests {
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
    use fusion_plus::fusion_order::{Self, FusionOrder};
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

    #[test]
    fun test_create_escrow_from_order() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order first
        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                hashes,
                metadata,
                ASSET_AMOUNT,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Create escrow from fusion order
        let escrow = escrow::deploy_source(&resolver_1, fusion_order, option::none());

        let escrow_address = object::object_address(&escrow);

        // Verify fusion order is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == ASSET_AMOUNT, 0);
        assert!(escrow::get_safety_deposit_amount(escrow) == SAFETY_DEPOSIT_AMOUNT, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&owner), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::get_hash(escrow) == *vector::borrow(&hashes, 0), 0);
        assert!(escrow::get_finality_duration(escrow) == FINALITY_DURATION, 0);
        assert!(escrow::get_exclusive_duration(escrow) == EXCLUSIVE_DURATION, 0);
        assert!(
            escrow::get_private_cancellation_duration(escrow)
                == PRIVATE_CANCELLATION_DURATION,
            0
        );

        // Verify assets are in escrow
        let escrow_main_balance =
            primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == ASSET_AMOUNT, 0);

        let escrow_safety_deposit_balance =
            primary_fungible_store::balance(
                escrow_address,
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_create_escrow_from_order_multiple_orders() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create multiple fusion orders
        let hashes1 = create_test_hashes(1);
        let hashes2 = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order1 =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                hashes1,
                metadata,
                ASSET_AMOUNT,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let order_hash2: vector<u8> = b"order_hash_456";
        let fusion_order2 =
            fusion_order::new(
                &owner,
                order_hash2,
                hashes2,
                metadata,
                ASSET_AMOUNT * 2,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Convert both to escrow
        let escrow1 = escrow::deploy_source(&resolver_1, fusion_order1, option::none());
        let escrow2 = escrow::deploy_source(&resolver_1, fusion_order2, option::none());

        let escrow1_address = object::object_address(&escrow1);
        let escrow2_address = object::object_address(&escrow2);

        // Verify both escrows exist
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_amount(escrow1) == ASSET_AMOUNT, 0);
        assert!(
            escrow::get_amount(escrow2) == ASSET_AMOUNT * 2,
            0
        );
        assert!(escrow::get_maker(escrow1) == signer::address_of(&owner), 0);
        assert!(escrow::get_maker(escrow2) == signer::address_of(&owner), 0);
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver_1), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&resolver_1), 0);
    }

    // - - - - SOURCE CHAIN FLOW TESTS (APT > ETH) - - - -

    #[test]
    fun test_source_chain_full_fill() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order = fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Create escrow with full fill (None parameter)
        let escrow = escrow::deploy_source(&resolver_1, fusion_order, option::none());

        let escrow_address = object::object_address(&escrow);

        // Verify fusion order is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == ASSET_AMOUNT, 0);
        assert!(escrow::get_safety_deposit_amount(escrow) == SAFETY_DEPOSIT_AMOUNT, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&owner), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == true, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == ASSET_AMOUNT, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_source_chain_partial_fill_single_segment() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order = fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Create escrow with partial fill (segment 0)
        let escrow = escrow::deploy_source(&resolver_1, fusion_order, option::some(0));

        let escrow_address = object::object_address(&escrow);

        // Verify fusion order still exists (not deleted for partial fills)
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == ASSET_AMOUNT / 10, 0); // 1/10 of total
        assert!(escrow::get_safety_deposit_amount(escrow) == SAFETY_DEPOSIT_AMOUNT / 10, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&owner), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == true, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == ASSET_AMOUNT / 10, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT / 10, 0);
    }

    #[test]
    fun test_source_chain_partial_fill_multiple_segments() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order = fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Create escrow with partial fill (segments 0-2, so 3 segments)
        let escrow = escrow::deploy_source(&resolver_1, fusion_order, option::some(2));

        let escrow_address = object::object_address(&escrow);

        // Verify fusion order still exists (not deleted for partial fills)
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == (ASSET_AMOUNT * 3) / 10, 0); // 3/10 of total
        assert!(escrow::get_safety_deposit_amount(escrow) == (SAFETY_DEPOSIT_AMOUNT * 3) / 10, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&owner), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == true, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == (ASSET_AMOUNT * 3) / 10, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance == (SAFETY_DEPOSIT_AMOUNT * 3) / 10, 0);
    }

    #[test]
    fun test_source_chain_partial_fill_sequential() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order = fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // First partial fill: segments 0-1 (2 segments)
        let escrow1 = escrow::deploy_source(&resolver_1, fusion_order, option::some(1));
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(escrow::get_amount(escrow1) == (ASSET_AMOUNT * 2) / 10, 0);
        assert!(escrow::get_safety_deposit_amount(escrow1) == (SAFETY_DEPOSIT_AMOUNT * 2) / 10, 0);

        // Second partial fill: segments 2-4 (3 segments)
        let escrow2 = escrow::deploy_source(&resolver_1, fusion_order, option::some(4));
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties
        assert!(escrow::get_amount(escrow2) == (ASSET_AMOUNT * 3) / 10, 0);
        assert!(escrow::get_safety_deposit_amount(escrow2) == (SAFETY_DEPOSIT_AMOUNT * 3) / 10, 0);

        // Verify both escrows exist
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);

        // Verify fusion order still exists (not completely filled yet)
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
    }

    #[test]
    fun test_source_chain_partial_fill_complete_order() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order = fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // Fill segments 0-8 (9 segments)
        let escrow1 = escrow::deploy_source(&resolver_1, fusion_order, option::some(8));
        let escrow1_address = object::object_address(&escrow1);

        // Verify first escrow properties
        assert!(escrow::get_amount(escrow1) == (ASSET_AMOUNT * 9) / 10, 0);
        assert!(escrow::get_safety_deposit_amount(escrow1) == (SAFETY_DEPOSIT_AMOUNT * 9) / 10, 0);

        // Fill remaining segment 9 (completes the order)
        let escrow2 = escrow::deploy_source(&resolver_1, fusion_order, option::some(9));
        let escrow2_address = object::object_address(&escrow2);

        // Verify second escrow properties (remaining amount)
        let remaining_amount = ASSET_AMOUNT - ((ASSET_AMOUNT * 9) / 10);
        let remaining_safety_deposit = SAFETY_DEPOSIT_AMOUNT - ((SAFETY_DEPOSIT_AMOUNT * 9) / 10);
        assert!(escrow::get_amount(escrow2) == remaining_amount, 0);
        assert!(escrow::get_safety_deposit_amount(escrow2) == remaining_safety_deposit, 0);

        // Verify both escrows exist
        assert!(object::object_exists<Escrow>(escrow1_address) == true, 0);
        assert!(object::object_exists<Escrow>(escrow2_address) == true, 0);

        // Verify fusion order is deleted (completely filled)
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);
    }

    #[test]
    fun test_source_chain_single_hash_full_fill() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order with single hash (no partial fills allowed)
        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order = fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Create escrow with full fill (None parameter)
        let escrow = escrow::deploy_source(&resolver_1, fusion_order, option::none());

        let escrow_address = object::object_address(&escrow);

        // Verify fusion order is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_order_hash(escrow) == ORDER_HASH, 0);
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == ASSET_AMOUNT, 0);
        assert!(escrow::get_safety_deposit_amount(escrow) == SAFETY_DEPOSIT_AMOUNT, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&owner), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver_1), 0);
        assert!(escrow::is_source_chain(escrow) == true, 0);

        // Verify assets are in escrow
        let escrow_main_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == ASSET_AMOUNT, 0);

        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address, object::address_to_object<Metadata>(@0xa)
        );
        assert!(escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_source_chain_withdrawal_with_segment_hash() {
        let (owner, _, _, resolver_1, _, _, metadata, _) = setup_test();

        // Create a fusion order with multiple hashes for partial fills
        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver_1));
        let auto_cancel_after = option::none<u64>();

        let fusion_order = fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );

        // Create escrow with partial fill (segment 2)
        let escrow = escrow::deploy_source(&resolver_1, fusion_order, option::some(2));

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Record initial balances
        let initial_resolver_balance = primary_fungible_store::balance(signer::address_of(&resolver_1), metadata);
        let initial_resolver_safety_deposit_balance = primary_fungible_store::balance(
            signer::address_of(&resolver_1), object::address_to_object<Metadata>(@0xa)
        );

        // Withdraw using the secret for segment 2
        let secret_2 = vector::empty<u8>();
        vector::append(&mut secret_2, b"secret_");
        vector::append(&mut secret_2, bcs::to_bytes(&2u64));
        escrow::withdraw(&resolver_1, escrow, secret_2);

        // Verify resolver received the assets
        let final_resolver_balance = primary_fungible_store::balance(signer::address_of(&resolver_1), metadata);
        assert!(final_resolver_balance == initial_resolver_balance + (ASSET_AMOUNT * 3) / 10, 0);

        // Verify resolver received safety deposit back
        let final_resolver_safety_deposit_balance = primary_fungible_store::balance(
            signer::address_of(&resolver_1), object::address_to_object<Metadata>(@0xa)
        );
        assert!(final_resolver_safety_deposit_balance == initial_resolver_safety_deposit_balance + (SAFETY_DEPOSIT_AMOUNT * 3) / 10, 0);
    }

}