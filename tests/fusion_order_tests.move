#[test_only]
module fusion_plus::fusion_order_tests {
    use aptos_std::aptos_hash;
    use std::bcs;
    use std::signer;
    use std::vector;
    use std::option::{Self, Option};
    use std::debug;
    use aptos_framework::account;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use fusion_plus::fusion_order::{Self, FusionOrder};
    use fusion_plus::common::{Self, safety_deposit_metadata};

    use fusion_plus::resolver_registry;
    // use fusion_plus::escrow::{Self, Escrow};

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

    fun setup_test(): (signer, signer, signer, Object<Metadata>, MintRef) {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
        let fusion_signer = account::create_account_for_test(@fusion_plus);

        let account_1 = common::initialize_account_with_fa(@0x201);
        let account_2 = common::initialize_account_with_fa(@0x202);
        let resolver = common::initialize_account_with_fa(@0x203);

        resolver_registry::init_module_for_test();
        resolver_registry::register_resolver(
            &fusion_signer, signer::address_of(&resolver)
        );

        let (metadata, mint_ref) = common::create_test_token(
            &fusion_signer, b"Test Token"
        );

        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_1));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_2));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&resolver));

        (account_1, account_2, resolver, metadata, mint_ref)
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
    fun test_create_fusion_order_single_secret() {
        let (account_1, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none<u64>();

        let fusion_order =
            fusion_order::new(
                &account_1,
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

        // Verify initial state
        assert!(
            fusion_order::get_maker(fusion_order) == signer::address_of(&account_1), 0
        );
        assert!(fusion_order::get_metadata(fusion_order) == metadata, 0);
        assert!(fusion_order::get_amount(fusion_order) == ASSET_AMOUNT, 0);
        assert!(fusion_order::get_order_hash(fusion_order) == ORDER_HASH, 0);
        assert!(
            fusion_order::get_hash(fusion_order) == *vector::borrow(&hashes, 0),
            0
        );

        // Verify safety deposit amount is correct
        assert!(
            fusion_order::get_safety_deposit_amount(fusion_order)
                == SAFETY_DEPOSIT_AMOUNT,
            0
        );
        assert!(
            fusion_order::get_finality_duration(fusion_order) == FINALITY_DURATION, 0
        );
        assert!(
            fusion_order::get_exclusive_duration(fusion_order) == EXCLUSIVE_DURATION, 0
        );
        assert!(
            fusion_order::get_private_cancellation_duration(fusion_order)
                == PRIVATE_CANCELLATION_DURATION,
            0
        );

        // Verify auto-cancel is disabled
        assert!(!fusion_order::is_auto_cancel_enabled(fusion_order), 0);

        // Verify the object exists
        let fusion_order_address = object::object_address(&fusion_order);
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Verify assets were transferred to the object
        let object_main_balance =
            primary_fungible_store::balance(fusion_order_address, metadata);
        assert!(object_main_balance == ASSET_AMOUNT, 0);

        let object_safety_deposit_balance =
            primary_fungible_store::balance(
                fusion_order_address,
                safety_deposit_metadata()
            );
        assert!(object_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_create_fusion_order_multiple_secrets() {
        let (account_1, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11); // 11 segments for partial fills
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 86400); // 24 hours

        let fusion_order =
            fusion_order::new(
                &account_1,
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

        // Verify initial state
        assert!(
            fusion_order::get_maker(fusion_order) == signer::address_of(&account_1), 0
        );
        assert!(fusion_order::get_metadata(fusion_order) == metadata, 0);
        assert!(fusion_order::get_amount(fusion_order) == ASSET_AMOUNT, 0);
        assert!(fusion_order::get_order_hash(fusion_order) == ORDER_HASH, 0);

        // Verify partial fills are allowed
        assert!(fusion_order::is_partial_fill_allowed(fusion_order), 0);

        // Verify auto-cancel is enabled
        assert!(fusion_order::is_auto_cancel_enabled(fusion_order), 0);

        // Verify the object exists
        let fusion_order_address = object::object_address(&fusion_order);
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Verify assets were transferred to the object
        let object_main_balance =
            primary_fungible_store::balance(fusion_order_address, metadata);
        assert!(object_main_balance == ASSET_AMOUNT, 0);

        let object_safety_deposit_balance =
            primary_fungible_store::balance(
                fusion_order_address,
                safety_deposit_metadata()
            );
        assert!(object_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0);
    }

    #[test]
    fun test_cancel_fusion_order_happy_flow() {
        let (owner, _, _, metadata, _) = setup_test();

        // Record initial balances
        let initial_main_balance =
            primary_fungible_store::balance(signer::address_of(&owner), metadata);
        let initial_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
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

        // Verify the object exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Owner cancels the order
        fusion_order::cancel(&owner, fusion_order);

        // Verify the object is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify owner received the main asset back
        let final_main_balance =
            primary_fungible_store::balance(signer::address_of(&owner), metadata);
        assert!(final_main_balance == initial_main_balance, 0);

        // Verify safety deposit is returned
        let final_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );
        assert!(final_safety_deposit_balance == initial_safety_deposit_balance, 0);
    }

    #[test]
    fun test_full_fill_order_single_secret() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none<u64>();

        let fusion_order =
            fusion_order::new(
                &maker,
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

        // Verify initial state
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Resolver accepts the full order (None for full fill)
        let (main_asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::none<u64>());

        // Verify the object is deleted (full fill)
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify resolver received the assets
        assert!(fungible_asset::amount(&main_asset) == ASSET_AMOUNT, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_multiple_partial_fills_correct() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11); // 11 segments
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none<u64>();

        let fusion_order =
            fusion_order::new(
                &maker,
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

        // Verify initial state
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Log initial balances
        let initial_main_balance = primary_fungible_store::balance(fusion_order_address, metadata);
        let initial_safety_balance = primary_fungible_store::balance(fusion_order_address, safety_deposit_metadata());
        debug::print(&b"Correct test - Initial balances:");
        debug::print(&initial_main_balance);
        debug::print(&initial_safety_balance);

        // First partial fill: segments 0-2 (3 segments)
        let (main_asset1, safety_deposit_asset1) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::some<u64>(2));

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify first fill amounts (3/10 of total)
        let expected_amount1 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit1 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset1) == expected_amount1, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset1) == expected_safety_deposit1, 0);

        // Clean up first assets
        primary_fungible_store::deposit(@0x0, main_asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        let last_filled_segment = fusion_order::get_last_filled_segment(fusion_order);
        assert!(last_filled_segment == option::some<u64>(2), 0);

        // Second partial fill: segments 3-5 (3 segments)
        let (main_asset2, safety_deposit_asset2) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::some<u64>(5));

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify second fill amounts (3/10 of total)
        let expected_amount2 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit2 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset2) == expected_amount2, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset2) == expected_safety_deposit2, 0);

        // Clean up second assets
        primary_fungible_store::deposit(@0x0, main_asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);

        // Third partial fill: segments 6-9 (4 segments) - CORRECT: don't use segment 10
        let (main_asset3, safety_deposit_asset3) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::some<u64>(9));

        // Verify third fill amounts (4/10 of total)
        let expected_amount3 = (ASSET_AMOUNT * 4) / 10;
        let expected_safety_deposit3 = (SAFETY_DEPOSIT_AMOUNT * 4) / 10;
        assert!(fungible_asset::amount(&main_asset3) == expected_amount3, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset3) == expected_safety_deposit3, 0);

        // Clean up third assets
        primary_fungible_store::deposit(@0x0, main_asset3);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset3);

        // Verify order is deleted (completely filled after third partial fill)
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);
    }


    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_SEGMENT)]
    fun test_multiple_partial_fills_incorrect_index() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11); // 11 segments
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none<u64>();

        let fusion_order =
            fusion_order::new(
                &maker,
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

        // Verify initial state
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Log initial balances
        let initial_main_balance = primary_fungible_store::balance(fusion_order_address, metadata);
        let initial_safety_balance = primary_fungible_store::balance(fusion_order_address, safety_deposit_metadata());
        debug::print(&b"Initial balances:");
        debug::print(&initial_main_balance);
        debug::print(&initial_safety_balance);

        // First partial fill: segments 0-2 (3 segments)
        let (main_asset1, safety_deposit_asset1) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::some<u64>(2));

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify first fill amounts (3/10 of total)
        let expected_amount1 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit1 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset1) == expected_amount1, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset1) == expected_safety_deposit1, 0);

        // Clean up first assets
        primary_fungible_store::deposit(@0x0, main_asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        let last_filled_segment = fusion_order::get_last_filled_segment(fusion_order);
        assert!(last_filled_segment == option::some<u64>(2), 0);

        // Log balances before second fill
        let second_main_balance = primary_fungible_store::balance(fusion_order_address, metadata);
        let second_safety_balance = primary_fungible_store::balance(fusion_order_address, safety_deposit_metadata());
        debug::print(&b"Before second fill:");
        debug::print(&second_main_balance);
        debug::print(&second_safety_balance);

        // Second partial fill: segments 3-5 (3 segments)
        let (main_asset2, safety_deposit_asset2) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::some<u64>(5));


        let last_filled_segment = fusion_order::get_last_filled_segment(fusion_order);
        debug::print(&last_filled_segment);
        assert!(last_filled_segment == option::some<u64>(5), 0);

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify second fill amounts (3/10 of total)
        let expected_amount2 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit2 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset2) == expected_amount2, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset2) == expected_safety_deposit2, 0);

        // Clean up second assets
        primary_fungible_store::deposit(@0x0, main_asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);

        // Log balances before final fill
        let final_main_balance = primary_fungible_store::balance(fusion_order_address, metadata);
        let final_safety_balance = primary_fungible_store::balance(fusion_order_address, safety_deposit_metadata());
        debug::print(&b"Before final fill:");
        debug::print(&final_main_balance);
        debug::print(&final_safety_balance);

        // Final fill: segments 6-10 (5 segments, completing the order) - THIS SHOULD FAIL
        // The last segment (10) is reserved for 100% fill only
        let (main_asset3, safety_deposit_asset3) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::some<u64>(10));

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset3);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset3);
    }

}
