module fusion_plus::dutch_auction {
    use std::signer;
    use std::option::{Self, Option};
    use std::vector;
    use aptos_framework::event::{Self};
    use aptos_framework::fungible_asset::{FungibleAsset, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef, ObjectGroup};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use fusion_plus::hashlock;

    // friend fusion_plus::escrow;
    friend fusion_plus::dutch_auction_tests;

    // - - - - ERROR CODES - - - -

    /// Invalid auction parameters
    const EINVALID_AUCTION_PARAMS: u64 = 1;
    /// Auction not started yet
    const EAUCTION_NOT_STARTED: u64 = 2;
    /// Auction already ended
    const EAUCTION_ENDED: u64 = 3;
    /// Invalid amount
    const EINVALID_AMOUNT: u64 = 4;
    /// Object does not exist
    const EOBJECT_DOES_NOT_EXIST: u64 = 5;
    /// Invalid caller
    const EINVALID_CALLER: u64 = 6;
    /// Auction already filled
    const EAUCTION_ALREADY_FILLED: u64 = 7;
    /// Invalid secret
    const EINVALID_SECRET: u64 = 8;
    /// Invalid segment
    const EINVALID_SEGMENT: u64 = 9;
    /// Segment already filled
    const ESEGMENT_ALREADY_FILLED: u64 = 10;
    /// Invalid segments
    const EINVALID_SEGMENTS: u64 = 11;
    /// Invalid safety deposit amount
    const EINVALID_SAFETY_DEPOSIT_AMOUNT: u64 = 12;

    // - - - - EVENTS - - - -

    #[event]
    /// Event emitted when a Dutch auction is created
    struct DutchAuctionCreatedEvent has drop, store {
        auction: Object<DutchAuction>,
        order_hash: vector<u8>,
        maker: address,
        metadata: Object<Metadata>,
        starting_amount: u64,
        ending_amount: u64,
        auction_start_time: u64,
        auction_end_time: u64,
        decay_duration: u64
    }

    #[event]
    /// Event emitted when an auction is filled
    struct DutchAuctionFilledEvent has drop, store {
        auction: Object<DutchAuction>,
        resolver: address,
        order_hash: vector<u8>,
        fill_amount: u64,
        fill_time: u64
    }

    #[event]
    /// Event emitted when an auction is cancelled
    struct DutchAuctionCancelledEvent has drop, store {
        auction: Object<DutchAuction>,
        maker: address,
        order_hash: vector<u8>
    }

    // - - - - STRUCTS - - - -

    /// A Dutch auction that determines the amount for ETH > APT orders.
    /// The amount starts high and decays over time until the auction ends.
    ///
    /// @param order_hash The hash of the associated order.
    /// @param maker The address of the maker who created the auction.
    /// @param metadata The metadata of the destination asset (APT).
    /// @param auction_params The auction parameters.
    /// @param is_filled Whether the auction has been filled.
    /// @param safety_deposit_amount The total safety deposit amount.
    /// @param last_filled_segment Track the last segment that was filled.
    /// @param hashes All secret hashes for partial fills.
    struct DutchAuction has key, store {
        order_hash: vector<u8>,
        maker: address,
        metadata: Object<Metadata>,
        auction_params: AuctionParams,
        is_filled: bool,
        safety_deposit_amount: u64,
        last_filled_segment: Option<u64>,
        hashes: vector<vector<u8>>
    }

    struct AuctionParams has store, copy, drop {
        starting_amount: u64,      // B tokens needed for 100% fill at start
        ending_amount: u64,        // B tokens needed for 100% fill at end
        auction_start_time: u64,
        auction_end_time: u64,
        decay_duration: u64        // Duration over which amount decays
    }

    // - - - - ENTRY FUNCTIONS - - - -

    /// Entry function for creating a new Dutch auction.
    public entry fun create_auction_entry(
        signer: &signer,
        order_hash: vector<u8>,
        hashes: vector<vector<u8>>,
        metadata: Object<Metadata>,
        starting_amount: u64,
        ending_amount: u64,
        auction_start_time: u64,
        auction_end_time: u64,
        decay_duration: u64,
        safety_deposit_amount: u64
    ) {
        create_auction(
            signer,
            order_hash,
            hashes,
            metadata,
            starting_amount,
            ending_amount,
            auction_start_time,
            auction_end_time,
            decay_duration,
            safety_deposit_amount
        );
    }

    /// Entry function for cancelling a Dutch auction (maker only).
    public entry fun cancel_auction_entry(
        signer: &signer,
        auction: Object<DutchAuction>
    ) acquires DutchAuction {
        cancel_auction(signer, auction);
    }

    // - - - - PUBLIC FUNCTIONS - - - -

    /// Creates a new Dutch auction for an ETH > APT order.
    ///
    /// @param signer The signer creating the auction.
    /// @param order_hash The hash of the associated order.
    /// @param hashes Vector of secret hashes for segments.
    /// @param metadata The metadata of the destination asset (APT).
    /// @param starting_amount The starting amount (B tokens) for 100% fill.
    /// @param ending_amount The ending amount (B tokens) for 100% fill.
    /// @param auction_start_time When the auction starts.
    /// @param auction_end_time When the auction ends.
    /// @param decay_duration Duration over which amount decays.
    /// @param safety_deposit_amount The total safety deposit amount.
    ///
    /// @reverts EINVALID_AUCTION_PARAMS if auction parameters are invalid.
    /// @reverts EINVALID_AMOUNT if amounts are invalid.
    /// @reverts EINVALID_SEGMENTS if hashes are invalid.
    /// @reverts EINVALID_SAFETY_DEPOSIT_AMOUNT if safety deposit is invalid.
    /// @return Object<DutchAuction> The created auction object.
    public fun create_auction(
        signer: &signer,
        order_hash: vector<u8>,
        hashes: vector<vector<u8>>,
        metadata: Object<Metadata>,
        starting_amount: u64,
        ending_amount: u64,
        auction_start_time: u64,
        auction_end_time: u64,
        decay_duration: u64,
        safety_deposit_amount: u64
    ): Object<DutchAuction> {
        let signer_address = signer::address_of(signer);

        // Validate auction parameters
        assert!(starting_amount > ending_amount, EINVALID_AUCTION_PARAMS);
        assert!(auction_start_time < auction_end_time, EINVALID_AUCTION_PARAMS);
        assert!(decay_duration > 0, EINVALID_AUCTION_PARAMS);
        assert!(auction_end_time > auction_start_time + decay_duration, EINVALID_AUCTION_PARAMS);

        // Validate amounts
        assert!(starting_amount > 0, EINVALID_AMOUNT);
        assert!(ending_amount > 0, EINVALID_AMOUNT);
        assert!(safety_deposit_amount > 0, EINVALID_SAFETY_DEPOSIT_AMOUNT);

        // Validate segments
        assert!(vector::length(&hashes) > 0, EINVALID_SEGMENTS);
        let num_hashes = vector::length(&hashes);
        if (num_hashes > 1) {
            // Validate that safety deposit is divisible by number of partial segments
            assert!(safety_deposit_amount % (num_hashes - 1) == 0, EINVALID_SAFETY_DEPOSIT_AMOUNT);
        };

        // Validate hashes
        for (i in 0..num_hashes) {
            assert!(is_valid_hash(&hashes[i]), EINVALID_SECRET);
        };

        // Create the object and DutchAuction
        let constructor_ref = object::create_object_from_account(signer);
        let object_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        let auction_params = AuctionParams {
            starting_amount,
            ending_amount,
            auction_start_time,
            auction_end_time,
            decay_duration
        };

        // Create the DutchAuction
        let auction = DutchAuction {
            order_hash,
            maker: signer_address,
            metadata,
            auction_params,
            is_filled: false,
            safety_deposit_amount,
            last_filled_segment: option::none(),
            hashes
        };

        move_to(&object_signer, auction);

        let auction_obj = object::object_from_constructor_ref(&constructor_ref);

        // Emit creation event
        event::emit(
            DutchAuctionCreatedEvent {
                auction: auction_obj,
                order_hash,
                maker: signer_address,
                metadata,
                starting_amount,
                ending_amount,
                auction_start_time,
                auction_end_time,
                decay_duration
            }
        );

        auction_obj
    }

    /// Cancels a Dutch auction. Only the maker can cancel.
    ///
    /// @param signer The signer cancelling the auction.
    /// @param auction The auction to cancel.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the auction does not exist.
    /// @reverts EINVALID_CALLER if the signer is not the maker.
    public fun cancel_auction(
        signer: &signer, auction: Object<DutchAuction>
    ) acquires DutchAuction {
        let signer_address = signer::address_of(signer);
        assert!(auction_exists(auction), EOBJECT_DOES_NOT_EXIST);
        assert!(is_maker(auction, signer_address), EINVALID_CALLER);

        let auction_address = object::object_address(&auction);
        let DutchAuction {
            order_hash,
            maker: _,
            metadata: _,
            auction_params: _,
            is_filled: _,
            safety_deposit_amount: _,
            last_filled_segment: _,
            hashes: _
        } = move_from<DutchAuction>(auction_address);

        // Emit cancellation event
        event::emit(
            DutchAuctionCancelledEvent {
                auction,
                maker: signer_address,
                order_hash
            }
        );
    }

    #[view]
    /// Calculates the current amount for 100% fill based on the current time.
    ///
    /// @param auction The auction to calculate the amount for.
    /// @return u64 The current amount for 100% fill.
    public fun get_current_amount(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_params = borrow_dutch_auction(&auction).auction_params;
        let current_time = timestamp::now_seconds();

        // If auction hasn't started yet, return starting amount
        if (current_time < auction_params.auction_start_time) {
            return auction_params.starting_amount
        };

        // If decay period is over, return ending amount
        let decay_end_time = auction_params.auction_start_time + auction_params.decay_duration;
        if (current_time >= decay_end_time) {
            return auction_params.ending_amount
        };

        // Calculate current amount based on decay
        let elapsed_time = current_time - auction_params.auction_start_time;
        let decay_progress = elapsed_time * 100 / auction_params.decay_duration; // 0-100%
        let amount_difference = auction_params.starting_amount - auction_params.ending_amount;
        let current_decay = (amount_difference * decay_progress) / 100;

        auction_params.starting_amount - current_decay
    }

    /// Fills a segment of the auction at the current amount. This should be called by the escrow
    /// when a resolver wants to accept the order at the current auction amount.
    ///
    /// @param signer The signer of the resolver filling the auction.
    /// @param auction The auction to fill.
    /// @param segment The segment index to fill, or None for full fill.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the auction does not exist.
    /// @reverts EAUCTION_NOT_STARTED if the auction hasn't started yet.
    /// @reverts EAUCTION_ALREADY_FILLED if the auction has already been filled.
    /// @reverts EINVALID_SEGMENT if segment index is invalid.
    /// @reverts ESEGMENT_ALREADY_FILLED if segment is already filled.
    /// @return (FungibleAsset, FungibleAsset) The main asset and safety deposit asset.
    public(friend) fun fill_auction(
        signer: &signer, auction: Object<DutchAuction>, segment: Option<u64>
    ): (FungibleAsset, FungibleAsset) acquires DutchAuction {
        let signer_address = signer::address_of(signer);
        let current_time = timestamp::now_seconds();

        assert!(auction_exists(auction), EOBJECT_DOES_NOT_EXIST);

        let current_amount = get_current_amount(auction);
        assert!(current_amount > 0, EINVALID_AMOUNT);

        let auction_ref = borrow_dutch_auction_mut(&auction);
        let auction_params = &auction_ref.auction_params;

        // Check if auction has started
        assert!(current_time >= auction_params.auction_start_time, EAUCTION_NOT_STARTED);

        // Check if auction is already completely filled
        assert!(!auction_ref.is_filled, EAUCTION_ALREADY_FILLED);

        let num_hashes = vector::length(&auction_ref.hashes);
        let segment_to_fill: u64;

        // Determine which segment to fill
        if (option::is_none(&segment)) {
            // Full fill - use last segment
            segment_to_fill = num_hashes - 1;
        } else {
            let segment_val = option::extract(&mut segment);
            // Validate segment index
            assert!(segment_val < num_hashes, EINVALID_SEGMENT);
            segment_to_fill = segment_val;
        };

        // Validate segment is not already filled and is filled in order
        if (option::is_some(&auction_ref.last_filled_segment)) {
            let last_segment = *option::borrow(&auction_ref.last_filled_segment);
            assert!(segment_to_fill > last_segment, ESEGMENT_ALREADY_FILLED);
        };

        // Calculate amount for this segment
        let segment_amount: u64;
        let safety_deposit_amount: u64;

        if (num_hashes == 1) {
            // Single hash auction - always full fill
            segment_amount = current_amount;
            safety_deposit_amount = auction_ref.safety_deposit_amount;
        } else {
            // Calculate segments to fill (from last_filled_segment + 1 up to segment_to_fill)
            let segments_to_fill =
                if (option::is_some(&auction_ref.last_filled_segment)) {
                    let last_segment = *option::borrow(&auction_ref.last_filled_segment);
                    segment_to_fill - last_segment
                } else {
                    segment_to_fill + 1 // +1 because segments are 0-indexed
                };

            if (segment_to_fill == num_hashes - 1) {
                // Full fill (last segment) - calculate remaining amount
                let filled_amount =
                    if (option::is_some(&auction_ref.last_filled_segment)) {
                        let last_segment = *option::borrow(&auction_ref.last_filled_segment);
                        let filled_segments_count = last_segment + 1;
                        filled_segments_count * (current_amount / (num_hashes - 1))
                    } else { 0 };
                segment_amount = current_amount - filled_amount;

                // Calculate remaining safety deposit
                let filled_safety_deposit =
                    if (option::is_some(&auction_ref.last_filled_segment)) {
                        let last_segment = *option::borrow(&auction_ref.last_filled_segment);
                        let filled_segments_count = last_segment + 1;
                        filled_segments_count * (auction_ref.safety_deposit_amount / (num_hashes - 1))
                    } else { 0 };
                safety_deposit_amount = auction_ref.safety_deposit_amount - filled_safety_deposit;
            } else {
                // Partial fill - calculate amount for segments from last_filled + 1 up to segment_to_fill
                segment_amount = segments_to_fill * (current_amount / (num_hashes - 1));
                safety_deposit_amount = segments_to_fill * (auction_ref.safety_deposit_amount / (num_hashes - 1));
            };
        };

        // Mark segment as filled
        option::swap_or_fill(&mut auction_ref.last_filled_segment, segment_to_fill);

        // Check if auction is completely filled
        if (segment_to_fill == num_hashes - 1 || segment_to_fill == num_hashes - 2) {
            auction_ref.is_filled = true;
        };

        // Withdraw assets from resolver to prevent gaming
        let asset = primary_fungible_store::withdraw(
            signer, auction_ref.metadata, segment_amount
        );

        let safety_deposit_asset = primary_fungible_store::withdraw(
            signer,
            safety_deposit_metadata(),
            safety_deposit_amount
        );

        // Emit fill event
        event::emit(
            DutchAuctionFilledEvent {
                auction,
                resolver: signer_address,
                order_hash: auction_ref.order_hash,
                fill_amount: segment_amount,
                fill_time: current_time
            }
        );

        (asset, safety_deposit_asset)
    }

    // - - - - VIEW FUNCTIONS - - - -

    #[view]
    /// Gets the order hash of an auction.
    ///
    /// @param auction The auction to get the order hash from.
    /// @return vector<u8> The order hash.
    public fun get_order_hash(auction: Object<DutchAuction>): vector<u8> acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.order_hash
    }

    #[view]
    /// Gets the maker address of an auction.
    ///
    /// @param auction The auction to get the maker from.
    /// @return address The maker address.
    public fun get_maker(auction: Object<DutchAuction>): address acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.maker
    }

    #[view]
    /// Gets the metadata of the destination asset in an auction.
    ///
    /// @param auction The auction to get the metadata from.
    /// @return Object<Metadata> The metadata of the destination asset.
    public fun get_metadata(auction: Object<DutchAuction>): Object<Metadata> acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.metadata
    }

    #[view]
    /// Gets the starting amount of an auction.
    ///
    /// @param auction The auction to get the starting amount from.
    /// @return u64 The starting amount.
    public fun get_starting_amount(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.auction_params.starting_amount
    }

    #[view]
    /// Gets the ending amount of an auction.
    ///
    /// @param auction The auction to get the ending amount from.
    /// @return u64 The ending amount.
    public fun get_ending_amount(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.auction_params.ending_amount
    }

    #[view]
    /// Gets the auction start time.
    ///
    /// @param auction The auction to get the start time from.
    /// @return u64 The auction start time.
    public fun get_auction_start_time(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.auction_params.auction_start_time
    }

    #[view]
    /// Gets the auction end time.
    ///
    /// @param auction The auction to get the end time from.
    /// @return u64 The auction end time.
    public fun get_auction_end_time(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.auction_params.auction_end_time
    }

    #[view]
    /// Gets the decay duration of an auction.
    ///
    /// @param auction The auction to get the decay duration from.
    /// @return u64 The decay duration.
    public fun get_decay_duration(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.auction_params.decay_duration
    }

    #[view]
    /// Checks if an auction is filled.
    ///
    /// @param auction The auction to check.
    /// @return bool True if the auction is filled, false otherwise.
    public fun is_filled(auction: Object<DutchAuction>): bool acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.is_filled
    }

    #[view]
    /// Checks if an auction has started.
    ///
    /// @param auction The auction to check.
    /// @return bool True if the auction has started, false otherwise.
    public fun has_started(auction: Object<DutchAuction>): bool acquires DutchAuction {
        let current_time = timestamp::now_seconds();
        let auction_ref = borrow_dutch_auction(&auction);
        current_time >= auction_ref.auction_params.auction_start_time
    }

    #[view]
    /// Checks if an auction has ended.
    ///
    /// @param auction The auction to check.
    /// @return bool True if the auction has ended, false otherwise.
    public fun has_ended(auction: Object<DutchAuction>): bool acquires DutchAuction {
        let current_time = timestamp::now_seconds();
        let auction_ref = borrow_dutch_auction(&auction);
        current_time >= auction_ref.auction_params.auction_end_time
    }

    #[view]
    /// Checks if partial fills are allowed for this auction.
    ///
    /// @param auction The auction to check.
    /// @return bool True if partial fills are allowed, false otherwise.
    public fun is_partial_fill_allowed(auction: Object<DutchAuction>): bool acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        vector::length(&auction_ref.hashes) > 1
    }

    #[view]
    /// Gets the safety deposit amount of the auction.
    ///
    /// @param auction The auction to get the safety deposit amount from.
    /// @return u64 The safety deposit amount.
    public fun get_safety_deposit_amount(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.safety_deposit_amount
    }

    #[view]
    /// Gets the last filled segment of the auction.
    ///
    /// @param auction The auction to get the last filled segment from.
    /// @return Option<u64> The last filled segment, or None if no segments filled.
    public fun get_last_filled_segment(
        auction: Object<DutchAuction>
    ): Option<u64> acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.last_filled_segment
    }

    #[view]
    /// Gets the segment amount for partial fills.
    /// Note: This is calculated dynamically based on current auction amount and number of hashes.
    ///
    /// @param auction The auction to get the segment amount from.
    /// @return u64 The segment amount.
    public fun get_segment_amount(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        let num_hashes = vector::length(&auction_ref.hashes);
        let current_amount = get_current_amount(auction);
        if (num_hashes > 1) {
            current_amount / (num_hashes - 1) // Each segment is equal
        } else {
            current_amount // Single segment for full fill
        }
    }

    #[view]
    /// Gets the maximum number of segments for partial fills.
    ///
    /// @param auction The auction to get the max segments from.
    /// @return u64 The maximum number of segments.
    public fun get_max_segments(auction: Object<DutchAuction>): u64 acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        vector::length(&auction_ref.hashes)
    }

    #[view]
    /// Checks if a specific segment is filled.
    ///
    /// @param auction The auction to check.
    /// @param segment The segment index to check.
    /// @return bool True if the segment is filled, false otherwise.
    public fun is_segment_filled(
        auction: Object<DutchAuction>, segment: u64
    ): bool acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        if (option::is_some(&auction_ref.last_filled_segment)) {
            let last_segment = *option::borrow(&auction_ref.last_filled_segment);
            segment <= last_segment
        } else {
            false
        }
    }

    /// Verifies a secret for a specific segment by comparing its hash.
    ///
    /// @param auction The auction.
    /// @param segment The segment index.
    /// @param secret The secret to verify.
    /// @return bool True if the secret is valid for this segment.
    public fun verify_secret_for_segment(
        auction: Object<DutchAuction>, segment: u64, secret: vector<u8>
    ): bool acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);

        assert!(segment < vector::length(&auction_ref.hashes), EINVALID_SEGMENT);
        let stored_hash = *vector::borrow(&auction_ref.hashes, segment);

        hashlock::verify_hash_with_secret(stored_hash, secret)
    }

    /// Gets the hash for a specific segment.
    ///
    /// @param auction The auction.
    /// @param segment The segment index.
    /// @return vector<u8> The hash for this segment.
    public fun get_segment_hash(
        auction: Object<DutchAuction>, segment: u64
    ): vector<u8> acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);

        assert!(segment < vector::length(&auction_ref.hashes), EINVALID_SEGMENT);
        *vector::borrow(&auction_ref.hashes, segment)
    }

    // - - - - UTILITY FUNCTIONS - - - -

    /// Checks if an auction exists.
    ///
    /// @param auction The auction object to check.
    /// @return bool True if the auction exists, false otherwise.
    public fun auction_exists(auction: Object<DutchAuction>): bool {
        object::object_exists<DutchAuction>(object::object_address(&auction))
    }

    /// Checks if a hash value is valid (non-empty).
    ///
    /// @param hash The hash value to check.
    /// @return bool True if the hash is valid, false otherwise.
    public fun is_valid_hash(hash: &vector<u8>): bool {
        hashlock::is_valid_hash(hash)
    }

    /// Gets the safety deposit metadata.
    ///
    /// @return Object<Metadata> The safety deposit metadata.
    fun safety_deposit_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(@0xa)
    }

    // - - - - TEST-ONLY FUNCTIONS - - - -

    #[test_only]
    /// Deletes a Dutch auction for testing purposes.
    ///
    /// @param auction The auction to delete.
    public fun delete_for_test(auction: Object<DutchAuction>) acquires DutchAuction {
        let auction_address = object::object_address(&auction);
        let DutchAuction {
            order_hash: _,
            maker: _,
            metadata: _,
            auction_params: _,
            is_filled: _,
            safety_deposit_amount: _,
            last_filled_segment: _,
            hashes: _
        } = move_from<DutchAuction>(auction_address);
    }

    #[test_only]
    /// Checks if an address is the maker of an auction.
    ///
    /// @param auction The auction to check.
    /// @param addr The address to check.
    /// @return bool True if the address is the maker, false otherwise.
    public fun is_maker(auction: Object<DutchAuction>, addr: address): bool acquires DutchAuction {
        let auction_ref = borrow_dutch_auction(&auction);
        auction_ref.maker == addr
    }

    // - - - - BORROW FUNCTIONS - - - -

    /// Borrows an immutable reference to the DutchAuction.
    ///
    /// @param auction_obj The auction object.
    /// @return &DutchAuction Immutable reference to the auction.
    inline fun borrow_dutch_auction(
        auction_obj: &Object<DutchAuction>
    ): &DutchAuction acquires DutchAuction {
        borrow_global<DutchAuction>(object::object_address(auction_obj))
    }

    /// Borrows a mutable reference to the DutchAuction.
    ///
    /// @param auction_obj The auction object.
    /// @return &mut DutchAuction Mutable reference to the auction.
    inline fun borrow_dutch_auction_mut(
        auction_obj: &Object<DutchAuction>
    ): &mut DutchAuction acquires DutchAuction {
        borrow_global_mut<DutchAuction>(object::object_address(auction_obj))
    }
}
