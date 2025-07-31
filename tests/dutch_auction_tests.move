#[test_only]
module fusion_plus::dutch_auction_tests {
    use std::signer;
    use std::option::{Self, Option};
    use std::vector;
    use aptos_std::aptos_hash;
    use aptos_framework::account;
    use aptos_framework::event::{Self};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use fusion_plus::dutch_auction::{Self, DutchAuction, AuctionParams};
    use fusion_plus::common::{Self, safety_deposit_metadata};
    use fusion_plus::hashlock;

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

    // - - - - HAPPY FLOW TESTS - - - -

    #[test]
    fun test_create_dutch_auction() {
        let (maker, _, _, metadata, _) = setup_test();

        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Verify initial state
        assert!(dutch_auction::get_maker(auction) == signer::address_of(&maker), 0);
        assert!(dutch_auction::get_metadata(auction) == metadata, 0);
        assert!(dutch_auction::get_order_hash(auction) == ORDER_HASH, 0);
        assert!(dutch_auction::get_starting_amount(auction) == STARTING_AMOUNT, 0);
        assert!(dutch_auction::get_ending_amount(auction) == ENDING_AMOUNT, 0);
        assert!(dutch_auction::get_auction_start_time(auction) == AUCTION_START_TIME, 0);
        assert!(dutch_auction::get_auction_end_time(auction) == AUCTION_END_TIME, 0);
        assert!(dutch_auction::get_decay_duration(auction) == DECAY_DURATION, 0);
        assert!(dutch_auction::get_safety_deposit_amount(auction) == SAFETY_DEPOSIT_AMOUNT, 0);

        // Verify the object exists
        let auction_address = object::object_address(&auction);
        assert!(object::object_exists<DutchAuction>(auction_address) == true, 0);

        // Verify initial state
        assert!(dutch_auction::is_filled(auction) == false, 0);
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
        let (maker, _, _, metadata, _) = setup_test();

        let hashes = vector::empty<vector<u8>>();
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_0));

        let auction = dutch_auction::create_auction(
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

        // Verify single segment behavior
        assert!(dutch_auction::is_partial_fill_allowed(auction) == false, 0);
        assert!(dutch_auction::get_max_segments(auction) == 1, 0);
        assert!(dutch_auction::get_segment_amount(auction) == STARTING_AMOUNT, 0);
    }

    #[test]
    fun test_get_current_amount_before_start() {
        let (maker, _, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Set time before auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME - 100);

        let current_amount = dutch_auction::get_current_amount(auction);
        assert!(current_amount == STARTING_AMOUNT, 0);
    }

    #[test]
    fun test_get_current_amount_during_decay() {
        let (maker, _, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Set time during decay period (50% through decay)
        timestamp::fast_forward_seconds(AUCTION_START_TIME + DECAY_DURATION / 2);

        let current_amount = dutch_auction::get_current_amount(auction);
        let expected_amount = STARTING_AMOUNT - (STARTING_AMOUNT - ENDING_AMOUNT) / 2;
        assert!(current_amount == expected_amount, 0);
    }

    #[test]
    fun test_get_current_amount_after_decay() {
        let (maker, _, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        let auction = dutch_auction::create_auction(
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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with None (full fill)
        let (asset1, safety_deposit_asset1) = dutch_auction::fill_auction(&resolver, auction, option::none<u64>());

        // Verify amounts
        assert!(fungible_asset::amount(&asset1) == STARTING_AMOUNT, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset1) == SAFETY_DEPOSIT_AMOUNT, 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset1);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset1);
    }

    #[test]
    fun test_fill_auction_single_hash_full_fill_with_segment() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = vector::empty<vector<u8>>();
        vector::push_back(&mut hashes, aptos_hash::keccak256(TEST_SECRET_0));

        let auction = dutch_auction::create_auction(
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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with Some(0) (full fill)
        let (asset, safety_deposit_asset) = dutch_auction::fill_auction(&resolver, auction, option::some<u64>(0));

        // Verify amounts
        assert!(fungible_asset::amount(&asset) == STARTING_AMOUNT, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_multiple_hash_full_fill_none() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Set time at auction start
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with None (full fill - should use last segment)
        let (asset, safety_deposit_asset) = dutch_auction::fill_auction(&resolver, auction, option::none<u64>());

        // Verify amounts
        assert!(fungible_asset::amount(&asset) == STARTING_AMOUNT, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0);

        // Verify auction is filled
        assert!(dutch_auction::is_filled(auction) == true, 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_multiple_hash_full_fill_last_segment() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill with last segment (10) - should give same result as None
        let (asset, safety_deposit_asset) = dutch_auction::fill_auction(&resolver, auction, option::some<u64>(10));

        // Verify amounts
        assert!(fungible_asset::amount(&asset) == STARTING_AMOUNT, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset) == SAFETY_DEPOSIT_AMOUNT, 0);

        // Verify auction is filled
        assert!(dutch_auction::is_filled(auction) == true, 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_partial_fill() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // Fill segment 2 (segments 0, 1, 2)
        let (asset, safety_deposit_asset) = dutch_auction::fill_auction(&resolver, auction, option::some<u64>(2));

        // Verify amounts (3 segments worth)
        let expected_amount = (STARTING_AMOUNT * 3) / 10;
        let expected_safety_deposit = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&asset) == expected_amount, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset) == expected_safety_deposit, 0);

        // Verify auction is not completely filled
        assert!(dutch_auction::is_filled(auction) == false, 0);
        assert!(dutch_auction::get_last_filled_segment(auction) == option::some<u64>(2), 0);

        // Clean up assets
        primary_fungible_store::deposit(@0x0, asset);
        primary_fungible_store::deposit(@0x0, safety_deposit_asset);
    }

    #[test]
    fun test_fill_auction_multiple_partial_fills() {
        let (maker, _, resolver, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Set time after auction starts
        timestamp::fast_forward_seconds(AUCTION_START_TIME);

        // First partial fill: segments 0-2 (3 segments)
        let (asset1, safety_deposit_asset1) = dutch_auction::fill_auction(&resolver, auction, option::some<u64>(2));
        let expected_amount1 = (STARTING_AMOUNT * 3) / 10;
        let expected_safety_deposit1 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&asset1) == expected_amount1, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset1) == expected_safety_deposit1, 0);

        // Second partial fill: segments 3-5 (3 segments)
        let (asset2, safety_deposit_asset2) = dutch_auction::fill_auction(&resolver, auction, option::some<u64>(5));
        let expected_amount2 = (STARTING_AMOUNT * 3) / 10;
        let expected_safety_deposit2 = (SAFETY_DEPOSIT_AMOUNT * 3) / 10;
        assert!(fungible_asset::amount(&asset2) == expected_amount2, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset2) == expected_safety_deposit2, 0);

        // Third partial fill: segments 6-9 (4 segments, completing the order)
        let (asset3, safety_deposit_asset3) = dutch_auction::fill_auction(&resolver, auction, option::some<u64>(9));
        let expected_amount3 = (STARTING_AMOUNT * 4) / 10;
        let expected_safety_deposit3 = (SAFETY_DEPOSIT_AMOUNT * 4) / 10;
        assert!(fungible_asset::amount(&asset3) == expected_amount3, 0);
        assert!(fungible_asset::amount(&safety_deposit_asset3) == expected_safety_deposit3, 0);

        // Verify auction is completely filled
        assert!(dutch_auction::is_filled(auction) == true, 0);
        assert!(dutch_auction::get_last_filled_segment(auction) == option::some<u64>(9), 0);

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
        let (maker, _, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Verify auction exists before cancellation
        assert!(dutch_auction::auction_exists(auction), 0);

        // Cancel the auction
        dutch_auction::cancel_auction(&maker, auction);

        // Verify auction no longer exists
        assert!(dutch_auction::auction_exists(auction) == false, 0);
    }

    #[test]
    fun test_verify_secret_for_segment() {
        let (maker, _, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

        // Test secret verification for different segments
        assert!(dutch_auction::verify_secret_for_segment(auction, 0, TEST_SECRET_0), 0);
        assert!(dutch_auction::verify_secret_for_segment(auction, 5, TEST_SECRET_5), 0);
        assert!(dutch_auction::verify_secret_for_segment(auction, 10, TEST_SECRET_10), 0);

        // Test wrong secrets
        assert!(dutch_auction::verify_secret_for_segment(auction, 0, TEST_SECRET_1) == false, 0);
        assert!(dutch_auction::verify_secret_for_segment(auction, 5, TEST_SECRET_0) == false, 0);

        // Cancel the auction
        dutch_auction::cancel_auction(&maker, auction);
    }

    #[test]
    fun test_get_segment_hash() {
        let (maker, _, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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
        let (maker, _, _, metadata, _) = setup_test();
        let hashes = create_test_hashes();

        let auction = dutch_auction::create_auction(
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

}
