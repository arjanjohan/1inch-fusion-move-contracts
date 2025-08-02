#[test_only]
module fusion_plus::fusion_order_tests {
    use aptos_std::aptos_hash;
    use std::bcs;
    use std::signer;
    use std::vector;
    use std::option::{Self};
    use aptos_framework::account;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use fusion_plus::fusion_order::{Self, FusionOrder};
    use fusion_plus::common::{Self, safety_deposit_metadata};

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
    const EXCLUSIVE_WITHDRAWAL_DURATION: u64 = 1800; // 30 minutes
    const PUBLIC_WITHDRAWAL_DURATION: u64 = 900; // 15 minutes
    const PRIVATE_CANCELLATION_DURATION: u64 = 900; // 15 minutes

    fun setup_test(): (signer, signer, signer, Object<Metadata>, MintRef) {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
        let fusion_signer = account::create_account_for_test(@fusion_plus);

        let account_1 = common::initialize_account_with_fa(@0x201);
        let account_2 = common::initialize_account_with_fa(@0x202);
        let resolver = common::initialize_account_with_fa(@0x203);

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
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
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
            fusion_order::get_exclusive_withdrawal_duration(fusion_order)
                == EXCLUSIVE_WITHDRAWAL_DURATION,
            0
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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
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
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
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
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify initial state
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Resolver accepts the full order (None for full fill)
        let (main_asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::none());

        // Verify the object is deleted (full fill)
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify resolver received the assets
        assert!(fungible_asset::amount(&main_asset) == ASSET_AMOUNT, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_multiple_partial_fills_correct() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11); // 11 segments
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify initial state
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // First partial fill: segments 0-2 (3 segments)
        let (main_asset1, safety_deposit_asset1) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(2)
            );

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify first fill amounts (3/10 of total)
        let expected_amount1 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit1 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset1) == expected_amount1, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset1) == expected_safety_deposit1,
            0
        );

        // Clean up first assets
        primary_fungible_store::deposit(@0x0, main_asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        let last_filled_segment = fusion_order::get_last_filled_segment(fusion_order);
        assert!(last_filled_segment == option::some<u64>(2), 0);

        // Second partial fill: segments 3-5 (3 segments)
        let (main_asset2, safety_deposit_asset2) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(5)
            );

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify second fill amounts (3/10 of total)
        let expected_amount2 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit2 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset2) == expected_amount2, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset2) == expected_safety_deposit2,
            0
        );

        // Clean up second assets
        primary_fungible_store::deposit(@0x0, main_asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);

        // Third partial fill: segments 6-9 (4 segments) - CORRECT: don't use segment 10
        let (main_asset3, safety_deposit_asset3) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(9)
            );

        // Verify third fill amounts (4/10 of total)
        let expected_amount3 = (ASSET_AMOUNT * 4) / 10;
        let expected_safety_deposit3 = (SAFETY_DEPOSIT_AMOUNT * 4) / 10;
        assert!(fungible_asset::amount(&main_asset3) == expected_amount3, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset3) == expected_safety_deposit3,
            0
        );

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
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify initial state
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // First partial fill: segments 0-2 (3 segments)
        let (main_asset1, safety_deposit_asset1) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(2)
            );

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify first fill amounts (3/10 of total)
        let expected_amount1 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit1 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset1) == expected_amount1, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset1) == expected_safety_deposit1,
            0
        );

        // Clean up first assets
        primary_fungible_store::deposit(@0x0, main_asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        let last_filled_segment = fusion_order::get_last_filled_segment(fusion_order);
        assert!(last_filled_segment == option::some<u64>(2), 0);

        // Second partial fill: segments 3-5 (3 segments)
        let (main_asset2, safety_deposit_asset2) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(5)
            );

        let last_filled_segment = fusion_order::get_last_filled_segment(fusion_order);
        assert!(last_filled_segment == option::some<u64>(5), 0);

        // Verify order still exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);
        assert!(!fusion_order::is_completely_filled(fusion_order), 0);

        // Verify second fill amounts (3/10 of total)
        let expected_amount2 = (ASSET_AMOUNT * 3) / 10;
        let expected_safety_deposit2 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&main_asset2) == expected_amount2, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset2) == expected_safety_deposit2,
            0
        );

        // Clean up second assets
        primary_fungible_store::deposit(@0x0, main_asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);

        // Final fill: segments 6-10 (5 segments, completing the order) - THIS SHOULD FAIL
        // The last segment (10) is reserved for 100% fill only
        let (main_asset3, safety_deposit_asset3) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(10)
            );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset3);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset3);
    }

    // - - - - ERROR CASES - - - -

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_AMOUNT)]
    fun test_create_fusion_order_zero_amount() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

        fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            0, // Zero amount should fail
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_HASH)]
    fun test_create_fusion_order_empty_hashes() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let empty_hashes = vector::empty<vector<u8>>();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

        fusion_order::new(
            &owner,
            ORDER_HASH,
            empty_hashes, // Empty hashes should fail
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINSUFFICIENT_BALANCE)]
    fun test_create_fusion_order_insufficient_balance() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

        let insufficient_amount = 1000000000000000; // Amount larger than available balance

        fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            insufficient_amount,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_RESOLVER_WHITELIST)]
    fun test_create_fusion_order_empty_resolver_whitelist() {
        let (owner, _, _, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let empty_whitelist = vector::empty<address>();
        let auto_cancel_after = option::none();

        fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            empty_whitelist, // Empty whitelist should fail
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_AMOUNT_FOR_PARTIAL_FILL)]
    fun test_create_fusion_order_invalid_amount_for_partial_fill() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11); // 11 hashes
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

        // Amount not divisible by (num_hashes - 1) = 10
        let invalid_amount = 100000001; // Not divisible by 10

        fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            invalid_amount,
            resolver_whitelist,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );
    }

    #[test]
    #[
        expected_failure(
            abort_code = fusion_order::EINVALID_SAFETY_DEPOSIT_AMOUNT_FOR_PARTIAL_FILL
        )
    ]
    fun test_create_fusion_order_invalid_safety_deposit_for_partial_fill() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11); // 11 hashes
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

        // Safety deposit not divisible by (num_hashes - 1) = 10
        let invalid_safety_deposit = 101; // Not divisible by 10

        fusion_order::new(
            &owner,
            ORDER_HASH,
            hashes,
            metadata,
            ASSET_AMOUNT,
            resolver_whitelist,
            invalid_safety_deposit,
            FINALITY_DURATION,
            EXCLUSIVE_WITHDRAWAL_DURATION,
            PUBLIC_WITHDRAWAL_DURATION,
            PRIVATE_CANCELLATION_DURATION,
            auto_cancel_after
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_CALLER)]
    fun test_cancel_fusion_order_wrong_caller() {
        let (owner, _, _, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let wrong_caller = account::create_account_for_test(@0x999);

        // Wrong caller tries to cancel the order
        fusion_order::cancel(&wrong_caller, fusion_order);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_RESOLVER)]
    fun test_resolver_accept_order_invalid_resolver() {
        let (owner, _, _, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Create a different account that's not in the whitelist
        let invalid_resolver = account::create_account_for_test(@0x901);

        // Try to accept order with invalid resolver
        let (asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(
                &invalid_resolver, fusion_order, option::none()
            );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EOBJECT_DOES_NOT_EXIST)]
    fun test_resolver_accept_order_nonexistent_order() {
        let (_, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

        // Create a fusion order
        let fusion_order =
            fusion_order::new(
                &resolver,
                ORDER_HASH,
                hashes,
                metadata,
                ASSET_AMOUNT,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Delete the order first
        fusion_order::delete_for_test(fusion_order);

        // Verify the order is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Try to accept deleted order
        let (asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(&resolver, fusion_order, option::none());

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::ESEGMENT_ALREADY_FILLED)]
    fun test_partial_fill_out_of_order() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // First partial fill: segments 0-2
        let (main_asset1, safety_deposit_asset1) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(2)
            );

        // Clean up first assets
        primary_fungible_store::deposit(@0x0, main_asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        // Try to fill segments 0-1 again (out of order) - should fail
        let (main_asset2, safety_deposit_asset2) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(1)
            );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::ESEGMENT_ALREADY_FILLED)]
    fun test_partial_fill_same_segment_twice() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // First partial fill: segments 0-2
        let (main_asset1, safety_deposit_asset1) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(2)
            );

        // Clean up first assets
        primary_fungible_store::deposit(@0x0, main_asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        // Try to fill segments 0-2 again (same segment) - should fail
        let (main_asset2, safety_deposit_asset2) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(2)
            );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);
    }

    // - - - - EDGE CASES - - - -

    #[test]
    fun test_cancel_fusion_order_multiple_orders() {
        let (owner, _, _, metadata, _) = setup_test();

        // Record initial safety deposit balance
        let initial_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );

        let hashes1 = create_test_hashes(1);
        let hashes2 = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Verify safety deposit was deducted for both orders
        let safety_deposit_after_creation =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );
        assert!(
            safety_deposit_after_creation
                == initial_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT * 2,
            0
        );

        // Cancel first order
        fusion_order::cancel(&owner, fusion_order1);

        // Verify first order safety deposit returned
        let safety_deposit_after_first_cancel =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );
        assert!(
            safety_deposit_after_first_cancel
                == safety_deposit_after_creation + SAFETY_DEPOSIT_AMOUNT,
            0
        );

        // Cancel second order
        fusion_order::cancel(&owner, fusion_order2);

        // Verify second order safety deposit returned
        let final_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );
        assert!(final_safety_deposit_balance == initial_safety_deposit_balance, 0);
    }

    #[test]
    fun test_cancel_fusion_order_different_owners() {
        let (owner1, owner2, _, metadata, _) = setup_test();

        // Record initial balances
        let initial_balance1 =
            primary_fungible_store::balance(signer::address_of(&owner1), metadata);
        let initial_balance2 =
            primary_fungible_store::balance(signer::address_of(&owner2), metadata);

        let hashes1 = create_test_hashes(1);
        let hashes2 = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

        let fusion_order1 =
            fusion_order::new(
                &owner1,
                ORDER_HASH,
                hashes1,
                metadata,
                ASSET_AMOUNT,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let order_hash2: vector<u8> = b"order_hash_456";
        let fusion_order2 =
            fusion_order::new(
                &owner2,
                order_hash2,
                hashes2,
                metadata,
                ASSET_AMOUNT * 2,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Each owner cancels their own order
        fusion_order::cancel(&owner1, fusion_order1);
        fusion_order::cancel(&owner2, fusion_order2);

        // Verify each owner received their funds back
        let final_balance1 =
            primary_fungible_store::balance(signer::address_of(&owner1), metadata);
        let final_balance2 =
            primary_fungible_store::balance(signer::address_of(&owner2), metadata);

        assert!(final_balance1 == initial_balance1, 0);
        assert!(final_balance2 == initial_balance2, 0);
    }

    #[test]
    fun test_cancel_fusion_order_large_amount() {
        let (owner, _, _, metadata, mint_ref) = setup_test();

        let large_amount = 1000000000000; // 1M tokens

        common::mint_fa(&mint_ref, large_amount, signer::address_of(&owner));

        // Record initial balance
        let initial_balance =
            primary_fungible_store::balance(signer::address_of(&owner), metadata);

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

        // Create the fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                hashes,
                metadata,
                large_amount,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Owner cancels the order
        fusion_order::cancel(&owner, fusion_order);

        // Verify owner received the funds back
        let final_balance =
            primary_fungible_store::balance(signer::address_of(&owner), metadata);
        assert!(final_balance == initial_balance, 0);
    }

    #[test]
    fun test_fusion_order_large_hash() {
        let (owner, _, _, metadata, _) = setup_test();

        // Create a large hash
        let large_secret = vector::empty<u8>();
        let i = 0;
        while (i < 1000) {
            vector::push_back(&mut large_secret, 255u8);
            i = i + 1;
        };

        let large_hash = aptos_hash::keccak256(large_secret);
        let hashes = vector::empty<vector<u8>>();
        vector::push_back(&mut hashes, large_hash);

        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Verify the hash is stored correctly
        assert!(fusion_order::get_hash(fusion_order) == large_hash, 0);

        // Cancel the order
        fusion_order::cancel(&owner, fusion_order);
    }

    #[test]
    fun test_fusion_order_multiple_resolvers() {
        let (owner, _, resolver1, metadata, _) = setup_test();

        // Add additional resolver
        let resolver2 = account::create_account_for_test(@0x204);

        let hashes1 = create_test_hashes(1);
        let hashes2 = create_test_hashes(1);
        let resolver_whitelist1 =
            create_resolver_whitelist(signer::address_of(&resolver1));
        let resolver_whitelist2 =
            create_resolver_whitelist(signer::address_of(&resolver2));
        let auto_cancel_after = option::none();

        let fusion_order1 =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                hashes1,
                metadata,
                ASSET_AMOUNT,
                resolver_whitelist1,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // First resolver accepts the order
        let (asset1, safety_deposit_asset1) =
            fusion_order::resolver_accept_order(
                &resolver1, fusion_order1, option::none()
            );

        // Verify assets are received
        assert!(fungible_asset::amount(&asset1) == ASSET_AMOUNT, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset1) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        let order_hash2: vector<u8> = b"order_hash_456";
        // Create another order for second resolver
        let fusion_order2 =
            fusion_order::new(
                &owner,
                order_hash2,
                hashes2,
                metadata,
                ASSET_AMOUNT * 2,
                resolver_whitelist2,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Second resolver accepts the order
        let (asset2, safety_deposit_asset2) =
            fusion_order::resolver_accept_order(
                &resolver2, fusion_order2, option::none()
            );

        // Verify assets are received
        assert!(
            fungible_asset::amount(&asset2) == ASSET_AMOUNT * 2,
            0
        );
        assert!(
            fungible_asset::amount(&safety_deposit_asset2) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);
    }

    #[test]
    fun test_fusion_order_safety_deposit_verification() {
        let (owner, _, _, metadata, _) = setup_test();

        // Record initial safety deposit balance
        let initial_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Verify safety deposit was transferred to fusion order
        let fusion_order_address = object::object_address(&fusion_order);
        let safety_deposit_at_object =
            primary_fungible_store::balance(
                fusion_order_address,
                safety_deposit_metadata()
            );
        assert!(safety_deposit_at_object == SAFETY_DEPOSIT_AMOUNT, 0);

        // Verify owner's safety deposit balance decreased
        let owner_safety_deposit_after_creation =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );
        assert!(
            owner_safety_deposit_after_creation
                == initial_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT,
            0
        );

        // Cancel the order
        fusion_order::cancel(&owner, fusion_order);

        // Verify safety deposit is returned
        let final_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                safety_deposit_metadata()
            );
        assert!(final_safety_deposit_balance == initial_safety_deposit_balance, 0);
    }

    // - - - - PARTIAL FILL EDGE CASES - - - -

    #[test]
    fun test_partial_fill_single_segment() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Fill just one segment (0)
        let (main_asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(0)
            );

        // Verify amounts (1/10 of total)
        let expected_amount = ASSET_AMOUNT / 10;
        let expected_safety_deposit = SAFETY_DEPOSIT_AMOUNT / 10;
        assert!(fungible_asset::amount(&main_asset) == expected_amount, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == expected_safety_deposit, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_partial_fill_almost_complete() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Fill segments 0-8 (9 segments, leaving 1 segment)
        let (main_asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(8)
            );

        // Verify amounts (9/10 of total)
        let expected_amount = (ASSET_AMOUNT * 9) / 10;
        let expected_safety_deposit = (SAFETY_DEPOSIT_AMOUNT * 9) / 10;
        assert!(fungible_asset::amount(&main_asset) == expected_amount, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == expected_safety_deposit, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_partial_fill_with_auto_cancel() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 3600); // 1 hour

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Verify auto-cancel is enabled
        assert!(fusion_order::is_auto_cancel_enabled(fusion_order), 0);

        // Fill segments 0-4 (5 segments)
        let (main_asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(4)
            );

        // Verify amounts (5/10 of total)
        let expected_amount = (ASSET_AMOUNT * 5) / 10;
        let expected_safety_deposit = (SAFETY_DEPOSIT_AMOUNT * 5) / 10;
        assert!(fungible_asset::amount(&main_asset) == expected_amount, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == expected_safety_deposit, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, main_asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_verify_secret_for_segment() {
        let (maker, _, _, metadata, _) = setup_test();

        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Test secret verification for different segments
        let secret_0 = vector::empty<u8>();
        vector::append(&mut secret_0, b"secret_");
        vector::append(&mut secret_0, bcs::to_bytes(&0u64));

        let secret_5 = vector::empty<u8>();
        vector::append(&mut secret_5, b"secret_");
        vector::append(&mut secret_5, bcs::to_bytes(&5u64));

        let wrong_secret = b"wrong_secret";

        // Verify correct secrets
        assert!(
            fusion_order::verify_secret_for_segment(fusion_order, 0, secret_0),
            0
        );
        assert!(
            fusion_order::verify_secret_for_segment(fusion_order, 5, secret_5),
            0
        );

        // Verify wrong secrets
        assert!(
            !fusion_order::verify_secret_for_segment(fusion_order, 0, wrong_secret),
            0
        );
        assert!(
            !fusion_order::verify_secret_for_segment(fusion_order, 5, wrong_secret),
            0
        );

        // Cancel the order
        fusion_order::cancel(&maker, fusion_order);
    }

    #[test]
    fun test_get_hash_for_segment() {
        let (maker, _, _, metadata, _) = setup_test();

        let hashes = create_test_hashes(11);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Test getting hashes for different segments
        let hash_0 = fusion_order::get_hash_for_segment(fusion_order, 0);
        let hash_5 = fusion_order::get_hash_for_segment(fusion_order, 5);
        let hash_10 = fusion_order::get_hash_for_segment(fusion_order, 10);

        // Verify hashes are correct
        assert!(hash_0 == *vector::borrow(&hashes, 0), 0);
        assert!(hash_5 == *vector::borrow(&hashes, 5), 0);
        assert!(hash_10 == *vector::borrow(&hashes, 10), 0);

        // Cancel the order
        fusion_order::cancel(&maker, fusion_order);
    }

    #[test]
    fun test_fusion_order_utility_functions() {
        let (owner, _, _, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(@0x203);
        let auto_cancel_after = option::none();

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Test order_exists
        assert!(fusion_order::order_exists(fusion_order), 0);

        // Test is_maker
        assert!(fusion_order::is_maker(fusion_order, signer::address_of(&owner)), 0);
        assert!(fusion_order::is_maker(fusion_order, @0x999) == false, 0);

        // Test with deleted order
        fusion_order::delete_for_test(fusion_order);
        assert!(fusion_order::order_exists(fusion_order) == false, 0);
    }

    // - - - - RESOLVER CANCELLATION TESTS - - - -

    #[test]
    fun test_resolver_cancel_happy_flow() {
        let (owner, _, resolver, metadata, _) = setup_test();
        let owner_address = signer::address_of(&owner);
        let resolver_address = signer::address_of(&resolver);

        // Record initial balances
        let initial_owner_balance =
            primary_fungible_store::balance(owner_address, metadata);
        let initial_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(resolver_address);
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 3600); // 1 hour

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Record balances after order creation
        let after_creation_owner_balance =
            primary_fungible_store::balance(owner_address, metadata);
        let after_creation_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let after_creation_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        // Verify balances after order creation
        assert!(
            after_creation_owner_balance == initial_owner_balance - ASSET_AMOUNT,
            0
        );
        assert!(
            after_creation_owner_safety_deposit_balance
                == initial_owner_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT,
            0
        );
        assert!(
            after_creation_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance,
            0
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify the object exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Fast forward to after auto-cancel timestamp
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + 7200); // 2 hours later

        // Resolver cancels the order
        fusion_order::cancel(&resolver, fusion_order);

        // Verify the object is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Record final balances
        let final_owner_balance = primary_fungible_store::balance(
            owner_address, metadata
        );
        let final_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        // Verify final balances
        assert!(final_owner_balance == initial_owner_balance, 0);
        assert!(
            final_owner_safety_deposit_balance
                == initial_owner_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT,
            0
        );
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance + SAFETY_DEPOSIT_AMOUNT,
            0
        );

    }

    #[test]
    fun test_resolver_cancel_partial_filled_order() {
        let (owner, _, resolver, metadata, _) = setup_test();
        let owner_address = signer::address_of(&owner);
        let resolver_address = signer::address_of(&resolver);

        // Record initial balances
        let initial_owner_balance =
            primary_fungible_store::balance(owner_address, metadata);
        let initial_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        let hashes = create_test_hashes(11); // Multiple hashes for partial fills
        let resolver_whitelist = create_resolver_whitelist(resolver_address);
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 3600); // 1 hour

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify the object exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Partially fill the order (segments 0-2)
        let (main_asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(
                &resolver, fusion_order, option::some<u64>(2)
            );

        // Clean up assets from partial fill
        primary_fungible_store::deposit(@0x0, main_asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);

        // Verify order still exists after partial fill
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Fast forward to after auto-cancel timestamp
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + 7200); // 2 hours later

        // Resolver cancels the partially filled order
        fusion_order::cancel(&resolver, fusion_order);

        // Verify the object is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Record final balances
        let final_owner_balance = primary_fungible_store::balance(
            owner_address, metadata
        );
        let final_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        // Verify final balances
        // Owner gets back their initial amount (minus what was already filled)
        assert!(
            final_owner_balance == initial_owner_balance - (ASSET_AMOUNT * 3) / 10,
            0
        );
        // Owner loses their safety deposit because the resolver cancelled the order
        assert!(
            final_owner_safety_deposit_balance
                == initial_owner_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT,
            0
        );
        // Resolver gets the remaining safety deposit
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance
                    + (SAFETY_DEPOSIT_AMOUNT * 7) / 10,
            0
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::ENOT_IN_RESOLVER_CANCELLATION_PERIOD)]
    fun test_resolver_cancel_before_auto_cancel_timestamp() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 3600); // 1 hour

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Try to cancel before auto-cancel timestamp (should fail)
        fusion_order::cancel(&resolver, fusion_order);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::ENOT_IN_RESOLVER_CANCELLATION_PERIOD)]
    fun test_resolver_cancel_no_auto_cancel_enabled() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::none(); // No auto-cancel

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Try to cancel when auto-cancel is not enabled (should fail)
        fusion_order::cancel(&resolver, fusion_order);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_CALLER)]
    fun test_resolver_cancel_wrong_resolver() {
        let (owner, _, resolver, metadata, _) = setup_test();

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 3600); // 1 hour

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Create a different resolver not in the whitelist
        let wrong_resolver = account::create_account_for_test(@0x999);

        // Fast forward to after auto-cancel timestamp
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + 7200); // 2 hours later

        // Wrong resolver tries to cancel the order (should fail)
        fusion_order::cancel(&wrong_resolver, fusion_order);
    }

    #[test]
    fun test_resolver_cancel_multiple_resolvers() {
        let (owner, _, resolver1, metadata, _) = setup_test();
        let owner_address = signer::address_of(&owner);
        let resolver1_address = signer::address_of(&resolver1);

        // Create additional resolver
        let resolver2 = account::create_account_for_test(@0x204);
        let resolver2_address = signer::address_of(&resolver2);

        // Record initial balances
        let initial_owner_balance =
            primary_fungible_store::balance(owner_address, metadata);
        let initial_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let initial_resolver1_safety_deposit_balance =
            primary_fungible_store::balance(
                resolver1_address, safety_deposit_metadata()
            );
        let initial_resolver2_safety_deposit_balance =
            primary_fungible_store::balance(
                resolver2_address, safety_deposit_metadata()
            );

        let hashes1 = create_test_hashes(1);
        let hashes2 = create_test_hashes(1);
        let resolver_whitelist1 = create_resolver_whitelist(resolver1_address);
        let resolver_whitelist2 = create_resolver_whitelist(resolver2_address);
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 3600); // 1 hour

        let fusion_order1 =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                hashes1,
                metadata,
                ASSET_AMOUNT,
                resolver_whitelist1,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
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
                resolver_whitelist2,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Fast forward to after auto-cancel timestamp
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + 7200); // 2 hours later

        // Each resolver cancels their own order
        fusion_order::cancel(&resolver1, fusion_order1);
        fusion_order::cancel(&resolver2, fusion_order2);

        // Record final balances
        let final_owner_balance = primary_fungible_store::balance(
            owner_address, metadata
        );
        let final_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let final_resolver1_safety_deposit_balance =
            primary_fungible_store::balance(
                resolver1_address, safety_deposit_metadata()
            );
        let final_resolver2_safety_deposit_balance =
            primary_fungible_store::balance(
                resolver2_address, safety_deposit_metadata()
            );

        // Verify final balances
        // Owner gets back their initial amounts
        assert!(final_owner_balance == initial_owner_balance, 0);
        // Owner loses their safety deposit because the resolvers cancelled the orders
        assert!(
            final_owner_safety_deposit_balance
                == initial_owner_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT * 2,
            0
        );
        // Each resolver gets the safety deposit
        assert!(
            final_resolver1_safety_deposit_balance
                == initial_resolver1_safety_deposit_balance + SAFETY_DEPOSIT_AMOUNT,
            0
        );
        assert!(
            final_resolver2_safety_deposit_balance
                == initial_resolver2_safety_deposit_balance + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }

    #[test]
    fun test_resolver_cancel_large_amount() {
        let (owner, _, resolver, metadata, mint_ref) = setup_test();
        let owner_address = signer::address_of(&owner);
        let resolver_address = signer::address_of(&resolver);

        let large_amount = 1000000000000; // 1M tokens

        // Mint large amount to owner
        common::mint_fa(&mint_ref, large_amount, owner_address);

        // Record initial balances
        let initial_owner_balance =
            primary_fungible_store::balance(owner_address, metadata);
        let initial_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(resolver_address);
        let auto_cancel_after = option::some<u64>(timestamp::now_seconds() + 3600); // 1 hour

        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                hashes,
                metadata,
                large_amount,
                resolver_whitelist,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        // Fast forward to after auto-cancel timestamp
        timestamp::update_global_time_for_test_secs(timestamp::now_seconds() + 7200); // 2 hours later

        // Resolver cancels the order
        fusion_order::cancel(&resolver, fusion_order);

        // Record final balances
        let final_owner_balance = primary_fungible_store::balance(
            owner_address, metadata
        );
        let final_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        // Verify final balances
        // Owner gets back their large amount
        assert!(final_owner_balance == initial_owner_balance, 0);
        // Owner gets back their safety deposit
        assert!(
            final_owner_safety_deposit_balance
                == initial_owner_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT,
            0
        );
        // Resolver gets the safety deposit
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }

    #[test]
    fun test_resolver_cancel_auto_cancel_timestamp_edge_case() {
        let (owner, _, resolver, metadata, _) = setup_test();
        let owner_address = signer::address_of(&owner);
        let resolver_address = signer::address_of(&resolver);

        let hashes = create_test_hashes(1);
        let resolver_whitelist = create_resolver_whitelist(resolver_address);
        let current_time = timestamp::now_seconds();
        let auto_cancel_after = option::some<u64>(current_time + 3600); // 1 hour

        // Record initial balances
        let initial_owner_balance =
            primary_fungible_store::balance(owner_address, metadata);
        let initial_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION,
                auto_cancel_after
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Fast forward to exactly the auto-cancel timestamp
        timestamp::update_global_time_for_test_secs(current_time + 3600);

        // Resolver cancels the order at exactly the auto-cancel timestamp
        fusion_order::cancel(&resolver, fusion_order);

        // Verify the object is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Record final balances
        let final_owner_balance = primary_fungible_store::balance(
            owner_address, metadata
        );
        let final_owner_safety_deposit_balance =
            primary_fungible_store::balance(owner_address, safety_deposit_metadata());
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(resolver_address, safety_deposit_metadata());

        // Verify final balances
        // Owner gets back their initial amount
        assert!(final_owner_balance == initial_owner_balance, 0);
        // Owner gets back their safety deposit
        assert!(
            final_owner_safety_deposit_balance
                == initial_owner_safety_deposit_balance - SAFETY_DEPOSIT_AMOUNT,
            0
        );
        // Resolver gets the safety deposit
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }
}
