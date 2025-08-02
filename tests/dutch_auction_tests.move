#[test_only]
module fusion_plus::dutch_auction_tests {
    use std::signer;
    use std::option::{Self};
    use std::vector;
    use aptos_std::aptos_hash;
    use aptos_framework::account;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use fusion_plus::dutch_auction::{Self, DutchAuction};
    use fusion_plus::common::{Self};

    // Test amounts
    const MINT_AMOUNT: u64 = 10000000000; // 100 token
    const STARTING_AMOUNT: u64 = 1000; // 1000 ETH for 100% fill at start
    const ENDING_AMOUNT: u64 = 500; // 500 ETH for 100% fill at end
    const SAFETY_DEPOSIT_AMOUNT: u64 = 100; // 100 ETH safety deposit

    // Test secrets and hashes
    const TEST_SECRET_0: vector<u8> = b"secret_0";
    const TEST_SECRET_1: vector<u8> = b"secret_1";
    const TEST_SECRET_2: vector<u8> = b"secret_2";
    const TEST_SECRET_3: vector<u8> = b"secret_3";
    const TEST_SECRET_4: vector<u8> = b"secret_4";
    const TEST_SECRET_5: vector<u8> = b"secret_5";
    const TEST_SECRET_6: vector<u8> = b"secret_6";
    const TEST_SECRET_7: vector<u8> = b"secret_7";
    const TEST_SECRET_8: vector<u8> = b"secret_8";
    const TEST_SECRET_9: vector<u8> = b"secret_9";
    const TEST_SECRET_10: vector<u8> = b"secret_10";

    // Test order parameters
    const ORDER_HASH: vector<u8> = b"order_hash_123";
    const AUCTION_START_TIME: u64 = 1000;
    const AUCTION_END_TIME: u64 = 2000;
    const DECAY_DURATION: u64 = 600; // 10 minutes decay

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

    fun setup_test_with_default_auction():
        (
        signer, signer, Object<Metadata>, Object<DutchAuction>
    ) {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));
        let auction =
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
        (maker, resolver, metadata, auction)
    }

    fun create_test_hashes(): vector<vector<u8>> {
        let hashes = vector::empty<vector<u8>>();
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_0));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_1));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_2));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_3));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_4));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_5));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_6));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_7));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_8));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_9));
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_10));
        hashes
    }

    fun create_resolver_whitelist(resolver: address): vector<address> {
        let whitelist = vector::empty<address>();
        vector::push_back(&mut whitelist, resolver);
        whitelist
    }

    // - - - - HAPPY FLOW TESTS - - - -

    #[test]
    fun test_create_dutch_auction() {
        let (maker, _, metadata, auction) = setup_test_with_default_auction();
        // Verify initial state
        assert!(dutch_auction::get_maker(auction) == signer::address_of(&maker), 0);
        assert!(dutch_auction::get_metadata(auction) == metadata, 0);
        assert!(dutch_auction::get_order_hash(auction) == ORDER_HASH, 0);
        assert!(dutch_auction::get_starting_amount(auction) == STARTING_AMOUNT, 0);
        assert!(dutch_auction::get_ending_amount(auction) == ENDING_AMOUNT, 0);
        assert!(dutch_auction::get_auction_start_time(auction) == AUCTION_START_TIME, 0);
        assert!(dutch_auction::get_auction_end_time(auction) == AUCTION_END_TIME, 0);
        assert!(dutch_auction::get_decay_duration(auction) == DECAY_DURATION, 0);
        assert!(
            dutch_auction::get_safety_deposit_amount(auction) == SAFETY_DEPOSIT_AMOUNT,
            0
        );

        // Verify the object exists
        let auction_address = object::object_address(&auction);
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Verify initial state
        assert!(dutch_auction::auction_exists(auction) == true, 0);
        assert!(option::is_none(&dutch_auction::get_last_filled_segment(auction)), 0);
        assert!(dutch_auction::is_partial_fill_allowed(auction) == true, 0);
        assert!(dutch_auction::get_max_segments(auction) == 11, 0);

        // Verify current amount calculation
        let current_amount = dutch_auction::get_current_amount(auction);
        assert!(current_amount == STARTING_AMOUNT, 0); // Should be starting amount before auction starts

        // Verify segment amount calculation
        let segment_amount = dutch_auction::get_segment_amount(auction);
        assert!(segment_amount == STARTING_AMOUNT / 10, 0); // Each segment is 1/10 of total
    }

    #[test]
    fun test_create_dutch_auction_single_segment() {
        let (maker, _, resolver, metadata, _) = setup_test();

        let hashes = vector::empty<vector<u8>>();
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_0));
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

        let auction =
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

        // Verify single segment behavior
        assert!(dutch_auction::is_partial_fill_allowed(auction) == false, 0);
        assert!(dutch_auction::get_max_segments(auction) == 1, 0);
        assert!(dutch_auction::get_segment_amount(auction) == STARTING_AMOUNT, 0);
    }

    #[test]
    fun test_get_current_amount_before_start() {
        let (_, _, _, auction) = setup_test_with_default_auction();

        // Set time before auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME - 100);

        let current_amount = dutch_auction::get_current_amount(auction);
        assert!(current_amount == STARTING_AMOUNT, 0);
    }

    #[test]
    fun test_get_current_amount_during_decay() {
        let (_, _, _, auction) = setup_test_with_default_auction();
        // Set time during decay period (50% through decay)
        timestamp::fast_forward_seconds(AUCTION_START_TIME + DECAY_DURATION / 2);

        let current_amount = dutch_auction::get_current_amount(auction);
        let expected_amount = STARTING_AMOUNT - (STARTING_AMOUNT - ENDING_AMOUNT) / 2;
        assert!(current_amount == expected_amount, 0);
    }

    #[test]
    fun test_get_current_amount_after_decay() {
        let (_, _, _, auction) = setup_test_with_default_auction();
        // Set time after decay period but before auction end
        timestamp::fast_forward_seconds(AUCTION_START_TIME + DECAY_DURATION + 100);

        let current_amount = dutch_auction::get_current_amount(auction);
        assert!(current_amount == ENDING_AMOUNT, 0);
    }

    #[test]
    fun test_fill_auction_single_hash_full_fill() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = vector::empty<vector<u8>>();
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_0));
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

        let auction =
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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with None (full fill)
        let (asset1, safety_deposit_asset1) =
            dutch_auction::fill_auction(&resolver, auction, option::none());

        // Verify amounts
        assert!(fungible_asset::amount(&asset1) == STARTING_AMOUNT, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset1) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);
    }

    #[test]
    fun test_fill_auction_single_hash_full_fill_with_segment() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = vector::empty<vector<u8>>();
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_0));
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

        let auction =
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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with Some(0) (full fill)
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(0));

        // Verify amounts
        assert!(fungible_asset::amount(&asset) == STARTING_AMOUNT, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_multiple_hash_full_fill_none() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();

        // Set time at auction start
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with None (full fill - should use last segment)
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::none());

        // Verify amounts
        assert!(fungible_asset::amount(&asset) == STARTING_AMOUNT, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Verify auction is filled
        assert!(dutch_auction::auction_exists(auction) == false, 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_multiple_hash_full_fill_last_segment() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with last segment (10) - should give same result as None
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(10));

        // Verify amounts
        assert!(fungible_asset::amount(&asset) == STARTING_AMOUNT, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Verify auction is filled
        assert!(dutch_auction::auction_exists(auction) == false, 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_partial_fill() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill segment 2 (segments 0, 1, 2)
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(2));

        // Verify amounts (3 segments worth)
        let expected_amount = (STARTING_AMOUNT * 3) / 10;
        let expected_safety_deposit = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&asset) == expected_amount, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == expected_safety_deposit, 0
        );

        // Verify auction is not completely filled
        assert!(dutch_auction::auction_exists(auction) == true, 0);
        assert!(
            dutch_auction::get_last_filled_segment(auction) == option::some<u64>(2),
            0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_multiple_partial_fills() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // First partial fill: segments 0-2 (3 segments)
        let (asset1, safety_deposit_asset1) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(2));
        let expected_amount1 = (STARTING_AMOUNT * 3) / 10;
        let expected_safety_deposit1 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&asset1) == expected_amount1, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset1) == expected_safety_deposit1,
            0
        );

        // Second partial fill: segments 3-5 (3 segments)
        let (asset2, safety_deposit_asset2) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(5));
        let expected_amount2 = (STARTING_AMOUNT * 3) / 10;
        let expected_safety_deposit2 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&asset2) == expected_amount2, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset2) == expected_safety_deposit2,
            0
        );

        // Third partial fill: segments 6-9 (4 segments, completing the order)
        let (asset3, safety_deposit_asset3) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(9));
        let expected_amount3 = (STARTING_AMOUNT * 4) / 10;
        let expected_safety_deposit3 = (SAFETY_DEPOSIT_AMOUNT * 4) / 10;
        assert!(fungible_asset::amount(&asset3) == expected_amount3, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset3) == expected_safety_deposit3,
            0
        );

        // Verify auction is completely filled
        assert!(dutch_auction::auction_exists(auction) == false, 0);
        assert!(
            dutch_auction::get_last_filled_segment(auction) == option::some<u64>(9),
            0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);
        primary_fungible_store::deposit(@0x0, asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);
        primary_fungible_store::deposit(@0x0, asset3);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset3);
    }

    #[test]
    fun test_cancel_auction() {
        let (maker, _, _, auction) = setup_test_with_default_auction();
        let auction_address = object::object_address(&auction);

        // Verify auction exists before cancellation
        assert!(dutch_auction::auction_exists(auction), 0);

        // Cancel the auction
        dutch_auction::cancel_auction(&maker, auction);

        // Verify auction no longer exists
        assert!(dutch_auction::auction_exists(auction) == false, 0);
        assert!(object::object_exists<DutchAuction>(auction_address) == false, 0);

    }

    #[test]
    fun test_verify_secret_for_segment() {
        let (maker, _, _, auction) = setup_test_with_default_auction();

        // Test secret verification for different segments
        assert!(
            dutch_auction::verify_secret_for_segment(auction, 0, TEST_SECRET_0),
            0
        );
        assert!(
            dutch_auction::verify_secret_for_segment(auction, 5, TEST_SECRET_5),
            0
        );
        assert!(
            dutch_auction::verify_secret_for_segment(auction, 10, TEST_SECRET_10),
            0
        );

        // Test wrong secrets
        assert!(
            dutch_auction::verify_secret_for_segment(auction, 0, TEST_SECRET_1) == false,
            0
        );
        assert!(
            dutch_auction::verify_secret_for_segment(auction, 5, TEST_SECRET_0) == false,
            0
        );

        // Cancel the auction
        dutch_auction::cancel_auction(&maker, auction);
    }

    #[test]
    fun test_get_segment_hash() {
        let (maker, _, _, auction) = setup_test_with_default_auction();
        // Test getting hashes for different segments
        let hash_0 = dutch_auction::get_segment_hash(auction, 0);
        let hash_5 = dutch_auction::get_segment_hash(auction, 5);
        let hash_10 = dutch_auction::get_segment_hash(auction, 10);

        // Verify hashes are correct
        assert!(hash_0 == aptos_hash::keccak256(TEST_SECRET_0), 0);
        assert!(hash_5 == aptos_hash::keccak256(TEST_SECRET_5), 0);
        assert!(hash_10 == aptos_hash::keccak256(TEST_SECRET_10), 0);

        // Cancel the auction
        dutch_auction::cancel_auction(&maker, auction);
    }

    #[test]
    fun test_auction_utility_functions() {
        let (maker, _, _, auction) = setup_test_with_default_auction();
        // Test auction_exists
        assert!(dutch_auction::auction_exists(auction), 0);

        // Test is_maker
        assert!(dutch_auction::is_maker(auction, signer::address_of(&maker)), 0);
        assert!(dutch_auction::is_maker(auction, @0x999) == false, 0);

        // Test has_started and has_ended
        timestamp::fast_forward_seconds(AUCTION_START_TIME - 100);
        assert!(dutch_auction::has_started(auction) == false, 0);
        assert!(dutch_auction::has_ended(auction) == false, 0);

        timestamp::fast_forward_seconds(100);
        assert!(dutch_auction::has_started(auction), 0);
        assert!(dutch_auction::has_ended(auction) == false, 0);

        timestamp::fast_forward_seconds(AUCTION_END_TIME - AUCTION_START_TIME);
        assert!(dutch_auction::has_started(auction), 0);
        assert!(dutch_auction::has_ended(auction), 0);

        // Test with deleted auction
        dutch_auction::delete_for_test(auction);
        assert!(dutch_auction::auction_exists(auction) == false, 0);
    }

    // - - - - ERROR AND EDGE CASE TESTS - - - -

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_AUCTION_PARAMS)]
    fun test_create_auction_invalid_params_starting_less_than_ending() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            ENDING_AMOUNT, // Starting amount less than ending amount
            STARTING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT,
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_AUCTION_PARAMS)]
    fun test_create_auction_invalid_params_zero_decay_duration() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_END_TIME,
            0, // Zero decay duration
            SAFETY_DEPOSIT_AMOUNT,
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_AUCTION_PARAMS)]
    fun test_create_auction_invalid_params_end_time_before_decay_complete() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            STARTING_AMOUNT,
            ENDING_AMOUNT,
            AUCTION_START_TIME,
            AUCTION_START_TIME + DECAY_DURATION - 100, // End time before decay completes
            DECAY_DURATION,
            SAFETY_DEPOSIT_AMOUNT,
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_AUCTION_PARAMS)]
    fun test_create_auction_invalid_params_zero_starting_amount() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

        dutch_auction::new(
            &maker,
            ORDER_HASH,
            hashes,
            metadata,
            0, // Zero starting amount
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
    fun test_create_auction_invalid_params_zero_safety_deposit() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

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
            0, // Zero safety deposit
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_SAFETY_DEPOSIT_AMOUNT)]
    fun test_create_auction_invalid_params_safety_deposit_not_divisible() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

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
            101, // Not divisible by 10 (num_hashes - 1)
            resolver_whitelist
        );
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_HASHES)]
    fun test_create_auction_invalid_params_empty_hashes() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = vector::empty<vector<u8>>();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

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
    #[expected_failure(abort_code = dutch_auction::EAUCTION_NOT_STARTED)]
    fun test_fill_auction_before_start() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time before auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME - 100);

        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(0));
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EOBJECT_DOES_NOT_EXIST)]
    fun test_fill_auction_already_filled() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill the auction completely
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::none());
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);

        // Try to fill again
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(0));
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_SEGMENT)]
    fun test_fill_auction_invalid_segment() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Try to fill invalid segment
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(11));
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::ESEGMENT_ALREADY_FILLED)]
    fun test_fill_auction_segment_already_filled() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill segment 0
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(0));
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);

        // Try to fill segment 0 again
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(0));
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::ESEGMENT_ALREADY_FILLED)]
    fun test_fill_auction_out_of_order() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill segment 2 first
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(2));
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);

        // Try to fill segment 1 first (should fail)
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(1));
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_CALLER)]
    fun test_cancel_auction_wrong_caller() {
        let (maker, wrong_caller, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&maker));

        let auction =
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

        // Try to cancel with wrong caller
        dutch_auction::cancel_auction(&wrong_caller, auction);
    }

    // - - - - ADDITIONAL HAPPY FLOW TESTS - - - -

    #[test]
    fun test_fill_auction_complete_with_partial_fills() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill segments 0-8 (9 partial fills)
        let i = 0;
        while (i < 9) {
            let (asset, safety_deposit_asset) =
                dutch_auction::fill_auction(&resolver, auction, option::some<u64>(i));

            // Verify segment fill
            let expected_amount = STARTING_AMOUNT / 10;
            let expected_safety_deposit = SAFETY_DEPOSIT_AMOUNT / 10;

            assert!(fungible_asset::amount(&asset) == expected_amount, 0);
            assert!(
                fungible_asset::amount(&safety_deposit_asset)
                    == expected_safety_deposit,
                0
            );

            // Clean up assets
            primary_fungible_store::deposit(@0x0, asset);
            primary_fungible_store::deposit(@0x0, safety_deposit_asset);

            i = i + 1;
        };

        // Fill the last segment (segment 9) to complete the auction
        let (final_asset, final_safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(9));

        // Verify final fill (remaining amount)
        let expected_final_amount = STARTING_AMOUNT - ((STARTING_AMOUNT * 9) / 10);
        let expected_final_safety_deposit =
            SAFETY_DEPOSIT_AMOUNT - ((SAFETY_DEPOSIT_AMOUNT * 9) / 10);
        assert!(fungible_asset::amount(&final_asset) == expected_final_amount, 0);
        assert!(
            fungible_asset::amount(&final_safety_deposit_asset)
                == expected_final_safety_deposit,
            0
        );
        assert!(dutch_auction::auction_exists(auction) == false, 0);

        // Clean up final assets
        primary_fungible_store::deposit(@0x0, final_asset);
        primary_fungible_store::deposit(@0x0, final_safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_large_amount() {
        let (maker, _, resolver, metadata, mint_ref) = setup_test();
        let large_amount = 1000000000000; // 1M tokens
        common::mint_fa(&mint_ref, large_amount, signer::address_of(&resolver));

        let hashes = create_test_hashes();
        let resolver_whitelist = create_resolver_whitelist(signer::address_of(&resolver));

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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill the auction completely
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::none());

        // Verify assets received
        assert!(fungible_asset::amount(&asset) == large_amount, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);

        // Verify auction is filled
        assert!(dutch_auction::auction_exists(auction) == false, 0);
    }

    #[test]
    fun test_fill_auction_during_decay() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time during decay (50% through)
        timestamp::fast_forward_seconds(AUCTION_START_TIME + DECAY_DURATION / 2);

        // Fill auction during decay
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::none());

        // Verify amounts are based on current decayed amount
        let expected_amount = STARTING_AMOUNT - (STARTING_AMOUNT - ENDING_AMOUNT) / 2;
        assert!(fungible_asset::amount(&asset) == expected_amount, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_after_decay() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after decay period but just before end time
        timestamp::fast_forward_seconds(AUCTION_END_TIME - 1);

        // Fill auction after decay
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(&resolver, auction, option::none());

        // Verify amounts are based on ending amount
        assert!(fungible_asset::amount(&asset) == ENDING_AMOUNT, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0
        );

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_remaining_segments() {
        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill segments 0-4 (5 segments)
        let (asset1, safety_deposit_asset1) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(4));
        let expected_amount1 = (STARTING_AMOUNT * 5) / 10;
        let expected_safety_deposit1 = (SAFETY_DEPOSIT_AMOUNT * 5) / 10;
        assert!(fungible_asset::amount(&asset1) == expected_amount1, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset1) == expected_safety_deposit1,
            0
        );

        // Clean up first assets
        primary_fungible_store::deposit(@0x0, asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        // Fill segments 5-8 (4 segments)
        let (asset2, safety_deposit_asset2) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(8));
        let expected_amount2 = (STARTING_AMOUNT * 4) / 10;
        let expected_safety_deposit2 = (SAFETY_DEPOSIT_AMOUNT * 4) / 10;
        assert!(fungible_asset::amount(&asset2) == expected_amount2, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset2) == expected_safety_deposit2,
            0
        );

        // Clean up second assets
        primary_fungible_store::deposit(@0x0, asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);

        // Verify auction is not completely filled and not deleted
        assert!(dutch_auction::auction_exists(auction) == true, 0);

        // Fill remaining segment 9 (1 segment)
        let (asset3, safety_deposit_asset3) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(9));
        let expected_amount3 = (STARTING_AMOUNT * 1) / 10;
        let expected_safety_deposit3 = (SAFETY_DEPOSIT_AMOUNT * 1) / 10;
        assert!(fungible_asset::amount(&asset3) == expected_amount3, 0);
        assert!(
            fungible_asset::amount(&safety_deposit_asset3) == expected_safety_deposit3,
            0
        );

        // Clean up third assets
        primary_fungible_store::deposit(@0x0, asset3);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset3);

        // Verify auction is completely filled
        assert!(dutch_auction::auction_exists(auction) == false, 0);
    }

    #[test]
    #[expected_failure(abort_code = dutch_auction::EINVALID_SEGMENT)]
    fun test_fill_auction_hash_10_with_partial_fills() {

        let (_, resolver, _, auction) = setup_test_with_default_auction();
        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill segment 0 first
        let (asset1, safety_deposit_asset1) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(0));
        primary_fungible_store::deposit(@0x0, asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);

        // Try to use hash 10 (segment 10) for 100% fill when partial fills exist - should fail
        let (asset2, safety_deposit_asset2) =
            dutch_auction::fill_auction(&resolver, auction, option::some<u64>(10));
        primary_fungible_store::deposit(@0x0, asset2);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset2);
    }
}
