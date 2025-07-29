#[test_only]
module fusion_plus::escrow_tests {
    use aptos_std::aptos_hash;
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
    use fusion_plus::resolver_registry;
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

        // Mint assets to accounts
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_1));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_2));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&resolver));

        (account_1, account_2, resolver, metadata, mint_ref)
    }

    #[test]
    fun test_create_escrow_from_order() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create a fusion order first
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Create escrow from fusion order
        let escrow = escrow::deploy_source(&resolver, fusion_order);

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
        assert!(escrow::get_taker(escrow) == signer::address_of(&resolver), 0);
        assert!(escrow::get_hash(escrow) == aptos_hash::keccak256(TEST_SECRET), 0);
        assert!(escrow::get_finality_duration(escrow) == FINALITY_DURATION, 0);
        assert!(escrow::get_exclusive_duration(escrow) == EXCLUSIVE_DURATION, 0);
        assert!(escrow::get_private_cancellation_duration(escrow) == PRIVATE_CANCELLATION_DURATION, 0);

        // Verify assets are in escrow
        let escrow_main_balance =
            primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_main_balance == ASSET_AMOUNT, 0);

        let escrow_safety_deposit_balance =
            primary_fungible_store::balance(
                escrow_address,
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0
        );
    }

    #[test]
    fun test_create_escrow_from_resolver() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        // Record initial balances
        let initial_resolver_main_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );

        // Create escrow directly from resolver
        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow_address = object::object_address(&escrow);

        // Verify escrow is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow properties
        assert!(escrow::get_metadata(escrow) == metadata, 0);
        assert!(escrow::get_amount(escrow) == ASSET_AMOUNT, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&resolver), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&recipient), 0);


        // Verify resolver's balances decreased
        let final_resolver_main_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );

        assert!(
            final_resolver_main_balance == initial_resolver_main_balance - ASSET_AMOUNT,
            0
        );
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance
                    - SAFETY_DEPOSIT_AMOUNT,
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
        assert!(
            escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0
        );
    }

    #[test]
    fun test_create_escrow_from_order_multiple_orders() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create multiple fusion orders
        let fusion_order1 =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let order_hash2: vector<u8> = b"order_hash_456";
        let fusion_order2 =
            fusion_order::new(
                &owner,
                order_hash2,
                aptos_hash::keccak256(WRONG_SECRET),
                metadata,
                ASSET_AMOUNT * 2,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Convert both to escrow
        let escrow1 = escrow::deploy_source(&resolver, fusion_order1);
        let escrow2 = escrow::deploy_source(&resolver, fusion_order2);

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
        assert!(escrow::get_taker(escrow1) == signer::address_of(&resolver), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&resolver), 0);
    }

    #[test]
    fun test_create_escrow_from_resolver_different_recipients() {
        let (recipient1, recipient2, resolver, metadata, _) = setup_test();

        // Create escrows with different recipients
        let escrow1 =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient1),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let order_hash2: vector<u8> = b"order_hash_456";
        let escrow2 =
            escrow::deploy_destination(
                &resolver,
                order_hash2,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient2),
                metadata,
                ASSET_AMOUNT * 2,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify escrow properties
        assert!(escrow::get_taker(escrow1) == signer::address_of(&recipient1), 0);
        assert!(escrow::get_taker(escrow2) == signer::address_of(&recipient2), 0);
        assert!(escrow::get_amount(escrow1) == ASSET_AMOUNT, 0);
        assert!(escrow::get_amount(escrow2) == ASSET_AMOUNT * 2, 0);

    }

    #[test]
    fun test_create_escrow_large_amount() {
        let (_, recipient, resolver, metadata, mint_ref) = setup_test();

        let large_amount = 1000000000000; // 1M tokens

        // Mint large amount to resolver
        common::mint_fa(&mint_ref, large_amount, signer::address_of(&resolver));

        // Record initial balance
        let initial_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);

        // Create escrow with large amount
        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                large_amount,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify escrow properties
        assert!(escrow::get_amount(escrow) == large_amount, 0);
        assert!(escrow::get_maker(escrow) == signer::address_of(&resolver), 0);
        assert!(escrow::get_taker(escrow) == signer::address_of(&recipient), 0);

        // Verify resolver's balance decreased
        let final_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);
        assert!(
            final_resolver_balance == initial_resolver_balance - large_amount,
            0
        );

        // Verify escrow has the assets
        let escrow_address = object::object_address(&escrow);
        let escrow_balance = primary_fungible_store::balance(escrow_address, metadata);
        assert!(escrow_balance == large_amount, 0);
    }

    #[test]
    fun test_escrow_timelock_and_hashlock() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify timelock is active
        let timelock = escrow::get_timelock(escrow);
        assert!(timelock::is_in_finality_phase(&timelock) == true, 0);

        // Verify hashlock is created with correct hash
        let hashlock = escrow::get_hashlock(escrow);
        assert!(hashlock::verify_hashlock(&hashlock, TEST_SECRET) == true, 0);
        assert!(hashlock::verify_hashlock(&hashlock, WRONG_SECRET) == false, 0);
    }

    #[test]
    fun test_escrow_phase_transitions() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let timelock = escrow::get_timelock(escrow);

        let (finality_duration, _, _) = timelock::get_durations(&timelock);

        // Initially in finality phase
        assert!(timelock::is_in_finality_phase(&timelock) == true, 0);
        assert!(timelock::is_in_exclusive_phase(&timelock) == false, 0);
        assert!(timelock::is_in_private_cancellation_phase(&timelock) == false, 0);
        assert!(timelock::is_in_public_cancellation_phase(&timelock) == false, 0);

        // Fast forward to exclusive phase
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        assert!(timelock::is_in_finality_phase(&timelock) == false, 0);
        assert!(timelock::is_in_exclusive_phase(&timelock) == true, 0);
        assert!(timelock::is_in_private_cancellation_phase(&timelock) == false, 0);
        assert!(timelock::is_in_public_cancellation_phase(&timelock) == false, 0);
    }

    #[test]
    fun test_escrow_safety_deposit_handling() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        // Record initial safety deposit balance
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );

        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let escrow_address = object::object_address(&escrow);

        // Verify resolver's safety deposit balance decreased
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance
                    - SAFETY_DEPOSIT_AMOUNT,
            0
        );

        // Verify escrow has safety deposit
        let escrow_safety_deposit_balance =
            primary_fungible_store::balance(
                escrow_address,
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            escrow_safety_deposit_balance == SAFETY_DEPOSIT_AMOUNT, 0
        );
    }

    #[test]
    fun test_escrow_object_lifecycle() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let fusion_order_address = object::object_address(&fusion_order);

        // Verify fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Convert to escrow
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        let escrow_address = object::object_address(&escrow);

        // Verify fusion order is deleted and escrow is created
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow controller exists
        assert!(
            object::object_exists<escrow::EscrowController>(escrow_address) == true, 0
        );
    }

    // - - - - SOURCE CHAIN SCENARIOS - - - -

    #[test]
    fun test_source_chain_escrow_withdrawal() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create fusion order (source chain scenario)
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Convert to escrow
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Record initial balances
        let initial_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );

        // Withdraw using correct secret
        escrow::withdraw(&resolver, escrow, TEST_SECRET);

        // Verify recipient received the assets
        let final_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);
        assert!(
            final_recipient_balance == initial_recipient_balance + ASSET_AMOUNT,
            0
        );

        // Verify resolver received safety deposit back
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance
                    + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_SECRET)]
    fun test_source_chain_escrow_withdrawal_wrong_secret() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create fusion order (source chain scenario)
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Convert to escrow
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Try to withdraw with wrong secret
        escrow::withdraw(&resolver, escrow, WRONG_SECRET);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_PHASE)]
    fun test_source_chain_escrow_withdrawal_wrong_phase() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create fusion order (source chain scenario)
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Convert to escrow
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        // Try to withdraw in finality phase (should fail)
        escrow::withdraw(&resolver, escrow, TEST_SECRET);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_CALLER)]
    fun test_source_chain_escrow_withdrawal_wrong_caller() {
        let (owner, recipient, resolver, metadata, _) = setup_test();

        // Create fusion order (source chain scenario)
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Convert to escrow
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        // Fast forward to exclusive phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, _, _) = timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration + 1
        );

        // Try to withdraw with wrong caller
        escrow::withdraw(&recipient, escrow, TEST_SECRET);
    }

    // - - - - DESTINATION CHAIN SCENARIOS - - - -

    #[test]
    fun test_destination_chain_escrow_withdrawal() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        // Create escrow directly from resolver (destination chain scenario)
        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
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
        let initial_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&recipient), metadata);
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );

        // Withdraw using correct secret
        escrow::withdraw(&resolver, escrow, TEST_SECRET);

        // Verify recipient received the assets
        let final_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&recipient), metadata);
        assert!(
            final_recipient_balance == initial_recipient_balance + ASSET_AMOUNT,
            0
        );

        // Verify resolver received safety deposit back
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance
                    + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_AMOUNT)]
    fun test_destination_chain_escrow_zero_amount() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        // Try to create escrow with zero amount
        escrow::deploy_destination(
            &resolver,
            ORDER_HASH,
            aptos_hash::keccak256(TEST_SECRET),
            signer::address_of(&recipient),
            metadata,
            0,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );

    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_HASH)]
    fun test_destination_chain_escrow_invalid_hash() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        // Try to create escrow with invalid hash

        escrow::deploy_destination(
            &resolver,
            ORDER_HASH,
            vector::empty(), // Empty hash should fail
            signer::address_of(&recipient),
            metadata,
            ASSET_AMOUNT,
            SAFETY_DEPOSIT_AMOUNT,
            FINALITY_DURATION,
            EXCLUSIVE_DURATION,
            PRIVATE_CANCELLATION_DURATION
        );
    }

    // - - - - RECOVERY SCENARIOS - - - -

    #[test]
    fun test_escrow_recovery_private_cancellation() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create escrow from fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        // Fast forward to private cancellation phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, exclusive_duration, _) =
            timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration
                + exclusive_duration + 1
        );

        // Record initial balances
        let initial_owner_balance =
            primary_fungible_store::balance(signer::address_of(&owner), metadata);
        let initial_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );

        // Recover escrow (only resolver can do this in private cancellation)
        escrow::recovery(&resolver, escrow);

        // Verify owner received the assets back
        let final_owner_balance =
            primary_fungible_store::balance(signer::address_of(&owner), metadata);
        assert!(
            final_owner_balance == initial_owner_balance + ASSET_AMOUNT,
            0
        );

        // Verify resolver received safety deposit back
        let final_resolver_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&resolver),
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            final_resolver_safety_deposit_balance
                == initial_resolver_safety_deposit_balance
                    + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }

    #[test]
    fun test_escrow_recovery_public_cancellation() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        // Create escrow from resolver
        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to public cancellation phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, exclusive_duration, private_cancellation_duration) =
            timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration
                + exclusive_duration + private_cancellation_duration + 1
        );

        // Record initial balances
        let initial_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);
        let initial_anyone_balance =
            primary_fungible_store::balance(
                signer::address_of(&recipient),
                object::address_to_object<Metadata>(@0xa)
            );

        // Anyone can recover in public cancellation phase
        escrow::recovery(&recipient, escrow);

        // Verify resolver received the assets back
        let final_resolver_balance =
            primary_fungible_store::balance(signer::address_of(&resolver), metadata);
        assert!(
            final_resolver_balance == initial_resolver_balance + ASSET_AMOUNT,
            0
        );

        // Verify anyone received safety deposit
        let final_anyone_balance =
            primary_fungible_store::balance(
                signer::address_of(&recipient),
                object::address_to_object<Metadata>(@0xa)
            );
        assert!(
            final_anyone_balance
                == initial_anyone_balance + SAFETY_DEPOSIT_AMOUNT,
            0
        );
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_CALLER)]
    fun test_escrow_recovery_private_cancellation_wrong_caller() {
        let (owner, recipient, resolver, metadata, _) = setup_test();

        // Create escrow from fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        // Fast forward to private cancellation phase
        let timelock = escrow::get_timelock(escrow);
        let (finality_duration, exclusive_duration, _) =
            timelock::get_durations(&timelock);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock) + finality_duration
                + exclusive_duration + 1
        );

        // Try to recover with wrong caller (only resolver can do this in private cancellation)
        escrow::recovery(&recipient, escrow);
    }

    #[test]
    #[expected_failure(abort_code = escrow::EINVALID_PHASE)]
    fun test_escrow_recovery_wrong_phase() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create escrow from fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let escrow = escrow::deploy_source(&resolver, fusion_order);

        // Try to recover in finality phase (should fail)
        escrow::recovery(&resolver, escrow);
    }

    // - - - - UTILITY FUNCTION TESTS - - - -

    #[test]
    fun test_escrow_utility_functions() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Test is_source_chain for destination chain scenario
        assert!(escrow::is_source_chain(escrow) == false, 0); // resolver != to

        // Test is_source_chain for source chain scenario
        let fusion_order =
            fusion_order::new(
                &recipient,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );
        let source_chain_escrow = escrow::deploy_source(&resolver, fusion_order);
        assert!(escrow::is_source_chain(source_chain_escrow) == true, 0); // resolver == to
    }

    // - - - - EDGE CASES - - - -

    #[test]
    fun test_escrow_large_amount_withdrawal() {
        let (_, recipient, resolver, metadata, mint_ref) = setup_test();

        let large_amount = 1000000000000; // 1M tokens

        // Mint large amount to resolver
        common::mint_fa(&mint_ref, large_amount, signer::address_of(&resolver));

        // Create escrow with large amount
        let escrow =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                large_amount,
                SAFETY_DEPOSIT_AMOUNT,
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
        let initial_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&recipient), metadata);

        // Withdraw large amount
        escrow::withdraw(&resolver, escrow, TEST_SECRET);

        // Verify recipient received the large amount
        let final_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&recipient), metadata);
        assert!(
            final_recipient_balance == initial_recipient_balance + large_amount,
            0
        );
    }

    #[test]
    fun test_escrow_multiple_withdrawals_same_secret() {
        let (_, recipient, resolver, metadata, _) = setup_test();

        // Create two escrows with same secret
        let escrow1 =
            escrow::deploy_destination(
                &resolver,
                ORDER_HASH,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let order_hash2: vector<u8> = b"order_hash_456";
        let escrow2 =
            escrow::deploy_destination(
                &resolver,
                order_hash2,
                aptos_hash::keccak256(TEST_SECRET),
                signer::address_of(&recipient),
                metadata,
                ASSET_AMOUNT * 2,
                SAFETY_DEPOSIT_AMOUNT,
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Fast forward to exclusive phase for both
        let timelock1 = escrow::get_timelock(escrow1);
        let (finality_duration, _, _) = timelock::get_durations(&timelock1);
        timestamp::update_global_time_for_test_secs(
            timelock::get_created_at(&timelock1) + finality_duration + 1
        );

        // Record initial balances
        let initial_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&recipient), metadata);

        // Withdraw from both escrows using same secret
        escrow::withdraw(&resolver, escrow1, TEST_SECRET);
        escrow::withdraw(&resolver, escrow2, TEST_SECRET);

        // Verify recipient received total amount
        let final_recipient_balance =
            primary_fungible_store::balance(signer::address_of(&recipient), metadata);
        assert!(
            final_recipient_balance
                == initial_recipient_balance + ASSET_AMOUNT + ASSET_AMOUNT * 2,
            0
        );
    }
}
