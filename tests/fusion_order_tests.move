#[test_only]
module fusion_plus::fusion_order_tests {
    use std::hash;
    use std::signer;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use fusion_plus::fusion_order::{Self, FusionOrder};
    use fusion_plus::common;
    use fusion_plus::constants;
    use fusion_plus::resolver_registry;
    use fusion_plus::escrow::{Self, Escrow};

    // Test accounts
    const CHAIN_ID: u64 = 20;

    // Test amounts
    const MINT_AMOUNT: u64 = 100000000; // 100 token
    const ASSET_AMOUNT: u64 = 1000000; // 1 token

    // Test secrets and hashes
    const TEST_SECRET: vector<u8> = b"my secret";
    const WRONG_SECRET: vector<u8> = b"wrong secret";

    fun setup_test(): (signer, signer, signer, Object<Metadata>, MintRef) {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
        let fusion_signer = account::create_account_for_test(@fusion_plus);

        let account_1 = common::initialize_account_with_fa(@0x201);
        let account_2 = common::initialize_account_with_fa(@0x202);
        let resolver = common::initialize_account_with_fa(@0x203);

        resolver_registry::init_module_for_test();
        resolver_registry::register_resolver(&fusion_signer, signer::address_of(&resolver));

        let (metadata, mint_ref) = common::create_test_token(&fusion_signer, b"Test Token");

        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_1));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&account_2));
        common::mint_fa(&mint_ref, MINT_AMOUNT, signer::address_of(&resolver));

        (account_1, account_2, resolver, metadata, mint_ref)
    }

    #[test]
    fun test_create_fusion_order() {
        let (account_1, _, _, metadata, _) = setup_test();

        let fusion_order =
            fusion_order::new(
                &account_1,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        // Verify initial state
        assert!(fusion_order::get_owner(fusion_order) == signer::address_of(&account_1), 0);
        assert!(fusion_order::get_metadata(fusion_order) == metadata, 0);
        assert!(fusion_order::get_amount(fusion_order) == ASSET_AMOUNT, 0);
        assert!(fusion_order::get_chain_id(fusion_order) == CHAIN_ID, 0);
        assert!(fusion_order::get_hash(fusion_order) == hash::sha3_256(TEST_SECRET), 0);

        // Verify safety deposit amount is correct
        assert!(
            fusion_order::get_safety_deposit_amount(fusion_order)
                == constants::get_safety_deposit_amount(),
            0
        );
        assert!(
            fusion_order::get_safety_deposit_metadata(fusion_order)
                == constants::get_safety_deposit_metadata(),
            0
        );

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
                constants::get_safety_deposit_metadata()
            );
        assert!(
            object_safety_deposit_balance == constants::get_safety_deposit_amount(), 0
        );
    }

    #[test]
    fun test_cancel_fusion_order_happy_flow() {
        let (owner, _, _, metadata, _) = setup_test();

        // Record initial balances
        let initial_main_balance = primary_fungible_store::balance(signer::address_of(&owner), metadata);
        let initial_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );

        let fusion_order =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify the object exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Owner cancels the order
        fusion_order::cancel(&owner, fusion_order);

        // Verify the object is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify owner received the main asset back
        let final_main_balance = primary_fungible_store::balance(signer::address_of(&owner), metadata);
        assert!(final_main_balance == initial_main_balance, 0);

        // Verify safety deposit is returned
        let final_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );
        assert!(final_safety_deposit_balance == initial_safety_deposit_balance, 0);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_CALLER)]
    fun test_cancel_fusion_order_wrong_caller() {
        let (owner, _, _, metadata, _) = setup_test();

        let wrong_caller = account::create_account_for_test(@0x999);

        let fusion_order =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        // Wrong caller tries to cancel the order
        fusion_order::cancel(&wrong_caller, fusion_order);
    }

    #[test]
    fun test_cancel_fusion_order_multiple_orders() {
        let (owner, _, _, metadata, _) = setup_test();

        // Record initial safety deposit balance
        let initial_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );

        let fusion_order1 =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        let fusion_order2 =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT * 2,
                CHAIN_ID,
                hash::sha3_256(WRONG_SECRET)
            );

        // Verify safety deposit was deducted for both orders
        let safety_deposit_after_creation =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );
        assert!(
            safety_deposit_after_creation
                == initial_safety_deposit_balance
                    - constants::get_safety_deposit_amount() * 2,
            0
        );

        // Cancel first order
        fusion_order::cancel(&owner, fusion_order1);

        // Verify first order safety deposit returned
        let safety_deposit_after_first_cancel =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );
        assert!(
            safety_deposit_after_first_cancel
                == safety_deposit_after_creation
                    + constants::get_safety_deposit_amount(),
            0
        );

        // Cancel second order
        fusion_order::cancel(&owner, fusion_order2);

        // Verify second order safety deposit returned
        let final_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );
        assert!(final_safety_deposit_balance == initial_safety_deposit_balance, 0);
    }

    #[test]
    fun test_cancel_fusion_order_different_owners() {
        let (owner1, owner2, _, metadata, _) = setup_test();

        // Record initial balances
        let initial_balance1 = primary_fungible_store::balance(signer::address_of(&owner1), metadata);
        let initial_balance2 = primary_fungible_store::balance(signer::address_of(&owner2), metadata);

        let fusion_order1 =
            fusion_order::new(
                &owner1,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        let fusion_order2 =
            fusion_order::new(
                &owner2,
                metadata,
                ASSET_AMOUNT * 2,
                CHAIN_ID,
                hash::sha3_256(WRONG_SECRET)
            );

        // Each owner cancels their own order
        fusion_order::cancel(&owner1, fusion_order1);
        fusion_order::cancel(&owner2, fusion_order2);

        // Verify each owner received their funds back
        let final_balance1 = primary_fungible_store::balance(signer::address_of(&owner1), metadata);
        let final_balance2 = primary_fungible_store::balance(signer::address_of(&owner2), metadata);

        assert!(final_balance1 == initial_balance1, 0);
        assert!(final_balance2 == initial_balance2, 0);
    }

    #[test]
    fun test_cancel_fusion_order_large_amount() {
        let (owner, _, _, metadata, mint_ref) = setup_test();

        let large_amount = 1000000000000; // 1M tokens

        common::mint_fa(&mint_ref, large_amount, signer::address_of(&owner));

        // Record initial balance
        let initial_balance = primary_fungible_store::balance(signer::address_of(&owner), metadata);

        // Create the fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                metadata,
                large_amount,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        // Owner cancels the order
        fusion_order::cancel(&owner, fusion_order);

        // Verify owner received the funds back
        let final_balance = primary_fungible_store::balance(signer::address_of(&owner), metadata);
        assert!(final_balance == initial_balance, 0);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_AMOUNT)]
    fun test_create_fusion_order_zero_amount() {
        let (owner, _, _, metadata, _) = setup_test();

        fusion_order::new(
            &owner,
            metadata,
            0, // Zero amount should fail
            CHAIN_ID,
            hash::sha3_256(TEST_SECRET)
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_HASH)]
    fun test_create_fusion_order_invalid_hash() {
        let (owner, _, _, metadata, _) = setup_test();

        fusion_order::new(
            &owner,
            metadata,
            ASSET_AMOUNT,
            CHAIN_ID,
            vector::empty() // Empty hash should fail
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINSUFFICIENT_BALANCE)]
    fun test_create_fusion_order_insufficient_balance() {
        let (owner, _, _, metadata, _) = setup_test();

        let insufficient_amount = 1000000000000000; // Amount larger than available balance

        fusion_order::new(
            &owner,
            metadata,
            insufficient_amount,
            CHAIN_ID,
            hash::sha3_256(TEST_SECRET)
        );
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EINVALID_RESOLVER)]
    fun test_resolver_accept_order_invalid_resolver() {
        let (owner, _, _, metadata, _) = setup_test();

        let fusion_order = fusion_order::new(
            &owner,
            metadata,
            ASSET_AMOUNT,
            CHAIN_ID,
            hash::sha3_256(TEST_SECRET)
        );

        // Create a different account that's not the resolver
        let invalid_resolver = account::create_account_for_test(@0x901);

        // Try to accept order with invalid resolver
        // Directly call resolver_accept_order
        let (asset, safety_deposit_asset) = fusion_order::resolver_accept_order(&invalid_resolver, fusion_order);

        // Deposit assets into 0x0
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);

    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EOBJECT_DOES_NOT_EXIST)]
    fun test_resolver_accept_order_nonexistent_order() {
        let (_, _, resolver, metadata, _) = setup_test();

        // Create a fusion order
        let fusion_order = fusion_order::new(
            &resolver,
            metadata,
            ASSET_AMOUNT,
            CHAIN_ID,
            hash::sha3_256(TEST_SECRET)
        );

        let fusion_order_address = object::object_address(&fusion_order);

        // Delete the order first
        fusion_order::delete_for_test(fusion_order);

        // Verify the order is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        let (asset, safety_deposit_asset) = fusion_order::resolver_accept_order(&resolver, fusion_order);

        // Deposit assets into 0x0
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fusion_order_utility_functions() {
        let (owner, _, _, metadata, _) = setup_test();

        let fusion_order = fusion_order::new(
            &owner,
            metadata,
            ASSET_AMOUNT,
            CHAIN_ID,
            hash::sha3_256(TEST_SECRET)
        );

        // Test is_valid_hash
        assert!(fusion_order::is_valid_hash(&hash::sha3_256(TEST_SECRET)), 0);
        assert!(fusion_order::is_valid_hash(&vector::empty()) == false, 0);

        // Test order_exists
        assert!(fusion_order::order_exists(fusion_order), 0);

        // Test is_owner
        assert!(fusion_order::is_owner(fusion_order, signer::address_of(&owner)), 0);
        assert!(fusion_order::is_owner(fusion_order, @0x999) == false, 0);

        // Test with deleted order
        fusion_order::delete_for_test(fusion_order);
        assert!(fusion_order::order_exists(fusion_order) == false, 0);
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

        let large_hash = hash::sha3_256(large_secret);

        let fusion_order = fusion_order::new(
            &owner,
            metadata,
            ASSET_AMOUNT,
            CHAIN_ID,
            large_hash
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
        let fusion_signer = account::create_account_for_test(@fusion_plus);
        resolver_registry::register_resolver(&fusion_signer, signer::address_of(&resolver2));

        let fusion_order = fusion_order::new(
            &owner,
            metadata,
            ASSET_AMOUNT,
            CHAIN_ID,
            hash::sha3_256(TEST_SECRET)
        );

        // First resolver accepts the order
        let (asset1, safety_deposit_asset1) = fusion_order::resolver_accept_order(&resolver1, fusion_order);

        // Verify assets are received
        assert!(fungible_asset::amount(&asset1) == ASSET_AMOUNT, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset1) == constants::get_safety_deposit_amount(), 0);

        // Deposit assets into resolver1
        primary_fungible_store::deposit(signer::address_of(&resolver1), asset1);
        primary_fungible_store::deposit(signer::address_of(&resolver1), safety_deposit_asset1);

        // Create another order for second resolver
        let fusion_order2 = fusion_order::new(
            &owner,
            metadata,
            ASSET_AMOUNT * 2,
            CHAIN_ID,
            hash::sha3_256(WRONG_SECRET)
        );

        // Second resolver accepts the order
        let (asset2, safety_deposit_asset2) = fusion_order::resolver_accept_order(&resolver2, fusion_order2);

        // Verify assets are received
        assert!(fungible_asset::amount(&asset2) == ASSET_AMOUNT * 2, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset2) == constants::get_safety_deposit_amount(), 0);

        // Deposit assets into resolver2
        primary_fungible_store::deposit(signer::address_of(&resolver2), asset2);
        primary_fungible_store::deposit(signer::address_of(&resolver2), safety_deposit_asset2);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EOBJECT_DOES_NOT_EXIST)]
    fun test_simulate_order_pickup_with_delete_for_test() {
        let (owner, _, _, metadata, _) = setup_test();

        let fusion_order =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify the object exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Simulate order pickup (this would normally be done by a resolver/escrow)
        fusion_order::delete_for_test(fusion_order);

        // Verify the object is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Order cannot be cancelled after pickup/delete
        fusion_order::cancel(&owner, fusion_order);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EOBJECT_DOES_NOT_EXIST)]
    fun test_simulate_order_pickup_with_new_from_order() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create a fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify the fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Simulate order pickup using escrow::new_from_order
        let escrow = escrow::new_from_order(&resolver, fusion_order);

        let escrow_address = object::object_address(&escrow);

        // Verify the fusion order is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify the escrow object is created
        assert!(object::object_exists<Escrow>(escrow_address) == true, 0);

        // Verify escrow object has the assets
        let escrow_main_balance = primary_fungible_store::balance(
            escrow_address,
            metadata
        );
        let escrow_safety_deposit_balance = primary_fungible_store::balance(
            escrow_address,
            constants::get_safety_deposit_metadata()
        );

        assert!(escrow_main_balance == ASSET_AMOUNT, 0);
        assert!(escrow_safety_deposit_balance == constants::get_safety_deposit_amount(), 0);

        // Order cannot be cancelled after pickup/delete
        fusion_order::cancel(&owner, fusion_order);
    }

    #[test]
    #[expected_failure(abort_code = fusion_order::EOBJECT_DOES_NOT_EXIST)]
    fun test_simulate_order_pickup_with_resolver_accept_order() {
        let (owner, _, resolver, metadata, _) = setup_test();

        // Create a fusion order
        let fusion_order =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        let fusion_order_address = object::object_address(&fusion_order);

        // Verify the fusion order exists
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == true, 0);

        // Directly call resolver_accept_order
        let (asset, safety_deposit_asset) = fusion_order::resolver_accept_order(&resolver, fusion_order);

        // Verify the fusion order is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);

        // Verify we received the correct assets
        assert!(fungible_asset::amount(&asset) == ASSET_AMOUNT, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset) == constants::get_safety_deposit_amount(), 0);

        // Deposit assets into 0x0
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);

        // Verify assets are in 0x0
        let burn_address_main_balance = primary_fungible_store::balance(@0x0, metadata);
        let burn_address_safety_deposit_balance = primary_fungible_store::balance(
            @0x0,
            constants::get_safety_deposit_metadata()
        );

        assert!(burn_address_main_balance == ASSET_AMOUNT, 0);
        assert!(burn_address_safety_deposit_balance == constants::get_safety_deposit_amount(), 0);

        // Order cannot be cancelled after pickup/delete
        fusion_order::cancel(&owner, fusion_order);

        // Verify the object is deleted
        assert!(object::object_exists<FusionOrder>(fusion_order_address) == false, 0);
    }

    #[test]
    fun test_fusion_order_safety_deposit_verification() {
        let (owner, _, _, metadata, _) = setup_test();

        // Record initial safety deposit balance
        let initial_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );

        let fusion_order =
            fusion_order::new(
                &owner,
                metadata,
                ASSET_AMOUNT,
                CHAIN_ID,
                hash::sha3_256(TEST_SECRET)
            );

        // Verify safety deposit was transferred to fusion order
        let fusion_order_address = object::object_address(&fusion_order);
        let safety_deposit_at_object =
            primary_fungible_store::balance(
                fusion_order_address,
                constants::get_safety_deposit_metadata()
            );
        assert!(safety_deposit_at_object == constants::get_safety_deposit_amount(), 0);

        // Verify owner's safety deposit balance decreased
        let owner_safety_deposit_after_creation =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );
        assert!(
            owner_safety_deposit_after_creation
                == initial_safety_deposit_balance
                    - constants::get_safety_deposit_amount(),
            0
        );

        // Cancel the order
        fusion_order::cancel(&owner, fusion_order);

        // Verify safety deposit is returned
        let final_safety_deposit_balance =
            primary_fungible_store::balance(
                signer::address_of(&owner),
                constants::get_safety_deposit_metadata()
            );
        assert!(final_safety_deposit_balance == initial_safety_deposit_balance, 0);
    }
}
