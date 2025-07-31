module fusion_plus::fusion_order {
    use std::signer;
    use std::vector;
    use std::debug;
    use aptos_framework::event::{Self};
    use aptos_framework::fungible_asset::{FungibleAsset, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef, ObjectGroup};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use fusion_plus::hashlock;
    use std::option::{Self, Option};

    friend fusion_plus::escrow;

    // - - - - ERROR CODES - - - -

    /// Invalid amount
    const EINVALID_AMOUNT: u64 = 1;
    /// Insufficient balance
    const EINSUFFICIENT_BALANCE: u64 = 2;
    /// Invalid caller
    const EINVALID_CALLER: u64 = 3;
    /// Object does not exist
    const EOBJECT_DOES_NOT_EXIST: u64 = 4;
    /// Invalid resolver
    const EINVALID_RESOLVER: u64 = 5;
    /// Invalid hash
    const EINVALID_HASH: u64 = 6;
    /// Invalid fill type
    const EINVALID_FILL_TYPE: u64 = 7;
    /// Insufficient remaining amount
    const EINSUFFICIENT_REMAINING: u64 = 8;
    /// Invalid secret
    const EINVALID_SECRET: u64 = 9;
    /// Invalid segment calculation
    const EINVALID_SEGMENT_CALCULATION: u64 = 10;
    /// Invalid segment hashes
    const EINVALID_SEGMENT_HASHES: u64 = 11;
    /// Invalid segment
    const EINVALID_SEGMENT: u64 = 12;
    /// Segment already filled
    const ESEGMENT_ALREADY_FILLED: u64 = 13;
    /// Invalid fill amount
    const EINVALID_FILL_AMOUNT: u64 = 14;
    /// Invalid amount for partial fill
    const EINVALID_AMOUNT_FOR_PARTIAL_FILL: u64 = 15;
    /// Invalid safety deposit amount for partial fill
    const EINVALID_SAFETY_DEPOSIT_AMOUNT_FOR_PARTIAL_FILL: u64 = 16;
    /// Invalid resolver whitelist
    const EINVALID_RESOLVER_WHITELIST: u64 = 17;
    /// Not in resolver cancellation period
    const ENOT_IN_RESOLVER_CANCELLATION_PERIOD: u64 = 18;

    // - - - - EVENTS - - - -

    #[event]
    /// Event emitted when a fusion order is created
    struct FusionOrderCreatedEvent has drop, store {
        fusion_order: Object<FusionOrder>,
        maker: address,
        order_hash: vector<u8>
    }

    #[event]
    /// Event emitted when a fusion order is cancelled by the maker
    struct FusionOrderCancelledEvent has drop, store {
        fusion_order: Object<FusionOrder>,
        maker: address,
        order_hash: vector<u8>,
        metadata: Object<Metadata>,
        amount: u64,
        safety_deposit_amount: u64
    }

    #[event]
    /// Event emitted when a fusion order is accepted by a resolver
    struct FusionOrderAcceptedEvent has drop, store {
        fusion_order: Object<FusionOrder>,
        resolver: address,
        maker: address,
        order_hash: vector<u8>,
        metadata: Object<Metadata>,
        filled_amount: u64,
        filled_safety_deposit_amount: u64,
        filled_segments: vector<u64> // Vector of segment indices that were filled
    }

    // - - - - STRUCTS - - - -

    #[resource_group_member(group = ObjectGroup)]
    /// Controller for managing the lifecycle of a FusionOrder.
    ///
    /// @param extend_ref The extend_ref of the fusion order, used to generate signer for the fusion order.
    /// @param delete_ref The delete ref of the fusion order, used to delete the fusion order.
    struct FusionOrderController has key {
        extend_ref: ExtendRef,
        delete_ref: DeleteRef
    }

    /// A fusion order that represents a user's intent to swap assets across chains.
    /// The order can be cancelled by the maker before a resolver picks it up.
    /// Once picked up by a resolver, the order is converted to an escrow.
    ///
    /// @param order_hash The hash of the order.
    /// @param hash The hash of the secret for the cross-chain swap.
    /// @param maker The address of the user who created this order.
    /// @param metadata The metadata of the asset being swapped.
    /// @param amount The amount of the asset being swapped.
    /// @param safety_deposit_amount The amount of safety deposit required.
    /// @param finality_duration The finality duration for the order.
    /// @param exclusive_duration The exclusive duration for the order.
    /// @param private_cancellation_duration The private cancellation duration for the order.
    /// @param partial_fill_allowed Whether partial fills are allowed.
    /// @param max_segments Maximum number of segments for partial fills.
    /// @param segment_amount Amount per segment.
    /// @param filled_amount Current filled amount.
    /// @param used_secrets Bitmap tracking which secrets have been used.
    /// @param segment_hashes Vector of hashes for each segment's secret.
    struct FusionOrder has key, store {
        order_hash: vector<u8>,
        hashes: vector<vector<u8>>,
        maker: address,
        metadata: Object<Metadata>,
        amount: u64,
        safety_deposit_amount: u64,
        resolver_whitelist: vector<address>,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64,
        last_filled_segment: Option<u64>,
        allow_resolver_to_cancel_after_timestamp: Option<u64>
    }

    // - - - - PUBLIC FUNCTIONS - - - -

    /// Creates a new FusionOrder with the specified parameters.
    ///
    /// @param signer The signer of the user creating the order.
    /// @param order_hash The hash of the order.
    /// @param maker The address of the maker.
    /// @param metadata The metadata of the asset being swapped.
    /// @param amount The amount of the asset being swapped.
    /// @param safety_deposit_amount The amount of safety deposit required.
    /// @param finality_duration The finality duration for the order.
    /// @param exclusive_duration The exclusive duration for the order.
    /// @param private_cancellation_duration The private cancellation duration for the order.
    /// @param auto_cancel_after Optional timestamp after which resolvers can cancel the order.
    ///
    /// @reverts EINVALID_AMOUNT if amount or safety deposit amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if user has insufficient balance for main asset.
    /// @reverts EINVALID_HASH if the order hash is invalid.
    /// @return Object<FusionOrder> The created fusion order object.
    public fun new(
        signer: &signer,
        order_hash: vector<u8>,
        hashes: vector<vector<u8>>,
        metadata: Object<Metadata>,
        amount: u64,
        resolver_whitelist: vector<address>,
        safety_deposit_amount: u64,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64,
        auto_cancel_after: Option<u64>
    ): Object<FusionOrder> {

        let signer_address = signer::address_of(signer);

        // Validate inputs
        assert!(amount > 0, EINVALID_AMOUNT);
        assert!(vector::length(&hashes) > 0, EINVALID_HASH);
        assert!(safety_deposit_amount > 0, EINVALID_AMOUNT);
        assert!(
            primary_fungible_store::balance(signer_address, metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );
        assert!(vector::length(&resolver_whitelist) > 0, EINVALID_RESOLVER_WHITELIST);
        let hashes_length = vector::length(&hashes);
        // Partial fill checks
        if (hashes_length > 1) {
            assert!(amount % (hashes_length - 1) == 0, EINVALID_AMOUNT_FOR_PARTIAL_FILL);
            assert!(safety_deposit_amount % ( hashes_length - 1) == 0, EINVALID_SAFETY_DEPOSIT_AMOUNT_FOR_PARTIAL_FILL);
        };
        for (i in 0..hashes_length) {
            assert!(is_valid_hash(&hashes[i]), EINVALID_HASH);
        };

        // Create an object and FusionOrder
        let constructor_ref = object::create_object_from_account(signer);
        let object_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Create the FusionOrder
        let fusion_order = FusionOrder {
            order_hash,
            hashes,
            maker: signer_address,
            metadata,
            amount,
            safety_deposit_amount,
            resolver_whitelist,
            finality_duration,
            exclusive_duration,
            private_cancellation_duration,
            last_filled_segment: option::none(),
            allow_resolver_to_cancel_after_timestamp: auto_cancel_after
        };

        move_to(&object_signer, fusion_order);

        // Create the controller
        move_to(
            &object_signer,
            FusionOrderController { extend_ref, delete_ref }
        );

        let object_address = signer::address_of(&object_signer);

        // Store the asset in the fusion order primary store
        primary_fungible_store::ensure_primary_store_exists(object_address, metadata);
        primary_fungible_store::transfer(signer, metadata, object_address, amount);

        // Transfer the safety deposit amount to fusion order primary store
        primary_fungible_store::transfer(
            signer,
            safety_deposit_metadata(),
            object_address,
            safety_deposit_amount
        );

        let fusion_order_obj = object::object_from_constructor_ref(&constructor_ref);

        // Emit creation event
        event::emit(
            FusionOrderCreatedEvent {
                fusion_order: fusion_order_obj,
                maker: signer_address,
                order_hash
            }
        );

        fusion_order_obj

    }

    /// Cancels a fusion order and returns remaining assets to the maker. This function can be called by the maker even if the order is partially filled.
    ///
    /// @param signer The signer of the order maker.
    /// @param fusion_order The fusion order to cancel.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the fusion order does not exist.
    /// @reverts EINVALID_CALLER if the signer is not the order maker.
    public fun cancel(
        signer: &signer, fusion_order: Object<FusionOrder>
    ) acquires FusionOrder, FusionOrderController {
        let signer_address = signer::address_of(signer);
        assert!(order_exists(fusion_order), EOBJECT_DOES_NOT_EXIST);

        // If maker doesn't cancel this order
        if (!(is_maker(fusion_order, signer_address))) {
            assert!(is_valid_resolver(fusion_order, signer_address), EINVALID_CALLER);
            assert!(is_auto_cancel_active(fusion_order), ENOT_IN_RESOLVER_CANCELLATION_PERIOD);
        };

        let object_address = object::object_address(&fusion_order);

        // Calculate remaining amounts
        let (remaining_amount, remaining_safety_deposit) = get_remaining_amounts(fusion_order);

        // Store event data before deletion
        let fusion_order_ref = borrow_fusion_order_mut(&fusion_order);
        let maker = fusion_order_ref.maker;
        let metadata = fusion_order_ref.metadata;
        let order_hash = fusion_order_ref.order_hash;

        let FusionOrderController { extend_ref, delete_ref } = move_from(object_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Return remaining main asset to owner
        primary_fungible_store::transfer(
            &object_signer,
            fusion_order_ref.metadata,
            maker,
            remaining_amount
        );

        // Return remaining safety deposit to maker or resolver
        primary_fungible_store::transfer(
            &object_signer,
            safety_deposit_metadata(),
            signer_address,
            remaining_safety_deposit
        );

        object::delete(delete_ref);

        // Emit cancellation event
        event::emit(
            FusionOrderCancelledEvent {
                fusion_order,
                maker,
                order_hash,
                metadata,
                amount: remaining_amount,
                safety_deposit_amount: remaining_safety_deposit
            }
        );

    }

    /// Allows an active resolver to accept a fusion order.
    /// This function is called from the escrow module when creating an escrow from a fusion order.
    /// If segment is None, the entire order is accepted (full fill). Otherwise, only up to the specified segment is accepted.
    ///
    /// @param signer The signer of the resolver accepting the order.
    /// @param fusion_order The fusion order to accept.
    /// @param segment The segment index to fill up to (inclusive), or None for full fill.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the fusion order does not exist.
    /// @reverts EINVALID_RESOLVER if the signer is not an active resolver.
    /// @reverts EINVALID_SEGMENT if segment index is invalid.
    /// @reverts ESEGMENT_ALREADY_FILLED if segment is already filled.
    /// @return (FungibleAsset, FungibleAsset) The main asset and safety deposit asset.
    public(friend) fun resolver_accept_order(
        signer: &signer, fusion_order: Object<FusionOrder>, segment: Option<u64>
    ): (FungibleAsset, FungibleAsset) acquires FusionOrder, FusionOrderController {
        let signer_address = signer::address_of(signer);

        assert!(order_exists(fusion_order), EOBJECT_DOES_NOT_EXIST);
        assert!(is_valid_resolver(fusion_order, signer_address), EINVALID_RESOLVER);

        if (option::is_none(&segment)) {
            // Full fill - use the last segment
            let fusion_order_ref = borrow_fusion_order(&fusion_order);
            let num_hashes = vector::length(&fusion_order_ref.hashes);
            accept_order_full(signer, fusion_order)
        } else {
            // Partial fill - use the specified segment
            let segment_val = option::extract(&mut segment);
            let fusion_order_ref = borrow_fusion_order(&fusion_order);
            let num_hashes = vector::length(&fusion_order_ref.hashes);

            // Validate segment index is valid for partial fills (can't use last segment)
            assert!(segment_val < num_hashes - 1, EINVALID_SEGMENT);

            // Validate segment is not already filled and is filled in order
            if (option::is_some(&fusion_order_ref.last_filled_segment)) {
                let last_segment = *option::borrow(&fusion_order_ref.last_filled_segment);
                assert!(segment_val > last_segment, ESEGMENT_ALREADY_FILLED);
            };

            accept_order_partial(signer, fusion_order, segment_val)
        }
    }

    /// Internal function to handle full order acceptance.
    ///
    /// @param signer The signer of the resolver.
    /// @param fusion_order The fusion order to accept.
    /// @param signer_address The address of the resolver.
    ///
    /// @return (FungibleAsset, FungibleAsset) The main asset and safety deposit asset.
    fun accept_order_full(
        signer: &signer, fusion_order: Object<FusionOrder>
    ): (FungibleAsset, FungibleAsset) acquires FusionOrder, FusionOrderController {
        let object_address = object::object_address(&fusion_order);
        let signer_address = signer::address_of(signer);
        let fusion_order_ref = borrow_fusion_order_mut(&fusion_order);
        let controller = borrow_fusion_order_controller_mut(&fusion_order);

        // Store event data before deletion
        let maker = fusion_order_ref.maker;
        let metadata = fusion_order_ref.metadata;
        let amount = fusion_order_ref.amount;
        let order_hash = fusion_order_ref.order_hash;
        let safety_deposit_amount = fusion_order_ref.safety_deposit_amount;

        let FusionOrderController { extend_ref, delete_ref } = move_from(object_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Withdraw main asset
        let asset = primary_fungible_store::withdraw(&object_signer, metadata, amount);

        let safety_deposit_asset =
            primary_fungible_store::withdraw(
                &object_signer,
                safety_deposit_metadata(),
                safety_deposit_amount
            );

        object::delete(delete_ref);

        // Get hash for the full fill (last segment)
        let num_hashes = vector::length(&fusion_order_ref.hashes);
        let full_fill_hash = get_hash_for_segment(fusion_order, num_hashes - 1);

        // Create vector of filled segments (all segments)
        let filled_segments = vector::empty<u64>();
        let i = 0;
        while (i < num_hashes) {
            vector::push_back(&mut filled_segments, i);
            i = i + 1;
        };

        // Emit acceptance event
        event::emit(
            FusionOrderAcceptedEvent {
                fusion_order,
                resolver: signer_address,
                maker,
                order_hash,
                metadata,
                filled_amount: amount,
                filled_safety_deposit_amount: safety_deposit_amount,
                filled_segments
            }
        );

        (asset, safety_deposit_asset)
    }

    /// Internal function to handle partial order acceptance.
    ///
    /// @param signer The signer of the resolver.
    /// @param fusion_order The fusion order to accept partially.
    /// @param segment The segment index to fill up to (inclusive).
    /// @param signer_address The address of the resolver.
    ///
    /// @return (FungibleAsset, FungibleAsset) The main asset and safety deposit asset.
    fun accept_order_partial(
        signer: &signer,
        fusion_order: Object<FusionOrder>,
        segment: u64
    ): (FungibleAsset, FungibleAsset) acquires FusionOrder, FusionOrderController {
        let signer_address = signer::address_of(signer);
        let fusion_order_ref = borrow_fusion_order_mut(&fusion_order);
        let num_hashes = vector::length(&fusion_order_ref.hashes);

        // Calculate which segments to fill
        let start_segment = if (option::is_some(&fusion_order_ref.last_filled_segment)) {
            *option::borrow(&fusion_order_ref.last_filled_segment) + 1
        } else {
            0
        };

        let segments_to_fill = segment - start_segment + 1;
        let segment_amount = fusion_order_ref.amount / (num_hashes - 1);
        let total_amount = segments_to_fill * segment_amount;

        // Calculate proportional safety deposit
        let proportional_safety_deposit =
            (fusion_order_ref.safety_deposit_amount * segments_to_fill) / (num_hashes - 1);

        let object_address = object::object_address(&fusion_order);
        let controller = borrow_fusion_order_controller_mut(&fusion_order);

        // Store event data before partial withdrawal
        let maker = fusion_order_ref.maker;
        let metadata = fusion_order_ref.metadata;
        let order_hash = fusion_order_ref.order_hash;
        let safety_deposit_amount = fusion_order_ref.safety_deposit_amount;

        let FusionOrderController { extend_ref, delete_ref } = move_from(object_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Withdraw partial main asset
        let asset = primary_fungible_store::withdraw(
            &object_signer, metadata, total_amount
        );

        let safety_deposit_asset =
            primary_fungible_store::withdraw(
                &object_signer,
                safety_deposit_metadata(),
                proportional_safety_deposit
            );

        // Update fusion order state
        option::swap_or_fill(&mut fusion_order_ref.last_filled_segment, segment);

        // Get hash for the segment being filled
        let segment_hash = get_hash_for_segment(fusion_order, segment);

        // Create vector of filled segments
        let filled_segments = vector::empty<u64>();
        let i = start_segment;
        while (i <= segment) {
            vector::push_back(&mut filled_segments, i);
            i = i + 1;
        };

        // Emit partial acceptance event
        event::emit(
            FusionOrderAcceptedEvent {
                fusion_order,
                resolver: signer_address,
                maker,
                order_hash,
                metadata,
                filled_amount: total_amount,
                filled_safety_deposit_amount: proportional_safety_deposit,
                filled_segments
            }
        );

        // If order is completely filled, delete it
        if (is_completely_filled(fusion_order)) {
            object::delete(delete_ref);
        } else {
            // Move controller back
            move_to(&object_signer, FusionOrderController { extend_ref, delete_ref });
        };

        (asset, safety_deposit_asset)
    }

    // - - - - GETTER FUNCTIONS - - - -

    /// Gets the order hash of a fusion order.
    ///
    /// @param fusion_order The fusion order to get the order hash from.
    /// @return vector<u8> The order hash.
    public fun get_order_hash(fusion_order: Object<FusionOrder>): vector<u8> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.order_hash
    }

    /// Gets the maker address of a fusion order.
    ///
    /// @param fusion_order The fusion order to get the maker from.
    /// @return address The maker address.
    public fun get_maker(fusion_order: Object<FusionOrder>): address acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.maker
    }

    /// Gets the metadata of the main asset in a fusion order.
    ///
    /// @param fusion_order The fusion order to get the metadata from.
    /// @return Object<Metadata> The metadata of the main asset.
    public fun get_metadata(
        fusion_order: Object<FusionOrder>
    ): Object<Metadata> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.metadata
    }

    /// Gets the amount of the main asset in a fusion order.
    ///
    /// @param fusion_order The fusion order to get the amount from.
    /// @return u64 The amount of the main asset.
    public fun get_amount(fusion_order: Object<FusionOrder>): u64 acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.amount
    }

    /// Gets the amount of the safety deposit in a fusion order.
    ///
    /// @param fusion_order The fusion order to get the safety deposit amount from.
    /// @return u64 The amount of the safety deposit.
    public fun get_safety_deposit_amount(
        fusion_order: Object<FusionOrder>
    ): u64 acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.safety_deposit_amount
    }

    /// Gets the finality duration of a fusion order.
    ///
    /// @param fusion_order The fusion order to get the finality duration from.
    /// @return u64 The finality duration.
    public fun get_finality_duration(fusion_order: Object<FusionOrder>): u64 acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.finality_duration
    }

    /// Gets the exclusive duration of a fusion order.
    ///
    /// @param fusion_order The fusion order to get the exclusive duration from.
    /// @return u64 The exclusive duration.
    public fun get_exclusive_duration(fusion_order: Object<FusionOrder>): u64 acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.exclusive_duration
    }

    /// Gets the private cancellation duration of a fusion order.
    ///
    /// @param fusion_order The fusion order to get the private cancellation duration from.
    /// @return u64 The private cancellation duration.
    public fun get_private_cancellation_duration(
        fusion_order: Object<FusionOrder>
    ): u64 acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.private_cancellation_duration
    }

    /// Gets the hash of the secret in a fusion order.
    ///
    /// @param fusion_order The fusion order to get the hash from.
    /// @return vector<u8> The hash of the secret.
    public fun get_hash(fusion_order: Object<FusionOrder>): vector<u8> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        // Return the first hash for backward compatibility
        *vector::borrow(&fusion_order_ref.hashes, 0)
    }

    /// Checks if a hash value is valid (non-empty).
    ///
    /// @param hash The hash value to check.
    /// @return bool True if the hash is valid, false otherwise.
    public fun is_valid_hash(hash: &vector<u8>): bool {
        hashlock::is_valid_hash(hash)
    }

    /// Checks if a fusion order exists.
    ///
    /// @param fusion_order The fusion order object to check.
    /// @return bool True if the fusion order exists, false otherwise.
    public fun order_exists(fusion_order: Object<FusionOrder>): bool {
        object::object_exists<FusionOrder>(object::object_address(&fusion_order))
    }

    /// Checks if an address is the maker of a fusion order.
    ///
    /// @param fusion_order The fusion order to check.
    /// @param address The address to check against.
    /// @return bool True if the address is the maker, false otherwise.
    public fun is_maker(
        fusion_order: Object<FusionOrder>, address: address
    ): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.maker == address
    }

    /// Checks if partial fills are allowed for this fusion order.
    ///
    /// @param fusion_order The fusion order to check.
    /// @return bool True if partial fills are allowed, false otherwise.
    public fun is_partial_fill_allowed(fusion_order: Object<FusionOrder>): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        vector::length(&fusion_order_ref.hashes) > 1
    }

    /// Gets the filled amount of the fusion order.
    ///
    /// @param fusion_order The fusion order to get the filled amount from.
    /// @return u64 The filled amount.
    public fun get_filled_amounts(fusion_order: Object<FusionOrder>): (u64, u64) acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        get_filled_amounts_internal(fusion_order_ref)
    }

    /// Gets the filled amount of the fusion order.
    ///
    /// @param fusion_order The fusion order to get the filled amount from.
    /// @return u64 The filled amount.
    fun get_filled_amounts_internal(fusion_order_ref: &FusionOrder): (u64, u64) {
        let num_hashes = vector::length(&fusion_order_ref.hashes);
        if (option::is_some(&fusion_order_ref.last_filled_segment)) {
            let last_segment = *option::borrow(&fusion_order_ref.last_filled_segment);
            let filled_segments_count = last_segment + 1;
            if (num_hashes > 1) {
                let filled_amount = filled_segments_count * (fusion_order_ref.amount / (num_hashes - 1));
                let filled_safety_deposit_amount = filled_segments_count * (fusion_order_ref.safety_deposit_amount / (num_hashes - 1));
                (filled_amount, filled_safety_deposit_amount)
            } else {
                (fusion_order_ref.amount, fusion_order_ref.safety_deposit_amount)
            }
        } else {
            (0, 0)
        }
    }

    /// Gets the remaining amount of the fusion order.
    ///
    /// @param fusion_order The fusion order to get the remaining amount from.
    /// @return u64 The remaining amount.
    public fun get_remaining_amounts(fusion_order: Object<FusionOrder>): (u64, u64) acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        let (filled_amount, filled_safety_deposit_amount) = get_filled_amounts_internal(fusion_order_ref);
        let remaining_amount = fusion_order_ref.amount - filled_amount;
        let remaining_safety_deposit = fusion_order_ref.safety_deposit_amount - filled_safety_deposit_amount;
        (remaining_amount, remaining_safety_deposit)
    }

    /// Checks if the fusion order is completely filled.
    ///
    /// @param fusion_order The fusion order to check.
    /// @return bool True if the order is completely filled, false otherwise.
    public fun is_completely_filled(fusion_order: Object<FusionOrder>): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        let num_hashes = vector::length(&fusion_order_ref.hashes);
        if (option::is_some(&fusion_order_ref.last_filled_segment)) {
            let last_segment = *option::borrow(&fusion_order_ref.last_filled_segment);
            if (num_hashes == 1) {
                last_segment == 0
            } else {
                // Partial order can be filled in a single fill (last segment) or in multiple fills (last segment - 1)
                last_segment == num_hashes - 1 || last_segment == num_hashes - 2
            }
        } else {
            false
        }
    }

    /// Gets the last filled segment of the fusion order.
    ///
    /// @param fusion_order The fusion order to get the last filled segment from.
    /// @return Option<u64> The last filled segment, or None if no segments filled.
    public fun get_last_filled_segment(fusion_order: Object<FusionOrder>): Option<u64> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.last_filled_segment
    }

    /// Verifies a secret for a specific segment by comparing its hash.
    ///
    /// @param fusion_order The fusion order.
    /// @param segment The segment index.
    /// @param secret The secret to verify.
    /// @return bool True if the secret is valid for this segment.
    public fun verify_secret_for_segment(
        fusion_order: Object<FusionOrder>, segment: u64, secret: vector<u8>
    ): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);

        assert!(segment < vector::length(&fusion_order_ref.hashes), EINVALID_SEGMENT);
        let stored_hash = *vector::borrow(&fusion_order_ref.hashes, segment);

        hashlock::verify_hash_with_secret(stored_hash, secret)
    }

    /// Gets the hash for a specific segment.
    ///
    /// @param fusion_order The fusion order.
    /// @param segment The segment index.
    /// @return vector<u8> The hash for this segment.
    public fun get_hash_for_segment(
        fusion_order: Object<FusionOrder>, segment: u64
    ): vector<u8> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);

        assert!(segment < vector::length(&fusion_order_ref.hashes), EINVALID_SEGMENT);
        *vector::borrow(&fusion_order_ref.hashes, segment)
    }

    /// Gets the maximum number of segments for the fusion order.
    ///
    /// @param fusion_order The fusion order.
    /// @return u64 The maximum number of segments.
    public fun get_max_segments(
        fusion_order: Object<FusionOrder>
    ): u64 acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        vector::length(&fusion_order_ref.hashes)
    }

    /// Gets the auto-cancel timestamp for the fusion order.
    ///
    /// @param fusion_order The fusion order.
    /// @return Option<u64> The auto-cancel timestamp, or None if not set.
    public fun get_auto_cancel_timestamp(
        fusion_order: Object<FusionOrder>
    ): Option<u64> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.allow_resolver_to_cancel_after_timestamp
    }

    /// Checks if auto-cancel is enabled for the fusion order.
    ///
    /// @param fusion_order The fusion order.
    /// @return bool True if auto-cancel is enabled, false otherwise.
    public fun is_auto_cancel_enabled(
        fusion_order: Object<FusionOrder>
    ): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        option::is_some(&fusion_order_ref.allow_resolver_to_cancel_after_timestamp)
    }

    /// Checks if the auto-cancel timestamp has passed for the fusion order.
    ///
    /// @param fusion_order The fusion order.
    /// @return bool True if auto-cancel timestamp has passed, false otherwise.
    public fun is_auto_cancel_active(
        fusion_order: Object<FusionOrder>
    ): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        if (option::is_some(&fusion_order_ref.allow_resolver_to_cancel_after_timestamp)) {
            let auto_cancel_timestamp = *option::borrow(&fusion_order_ref.allow_resolver_to_cancel_after_timestamp);
            let current_time = timestamp::now_seconds();
            current_time >= auto_cancel_timestamp
        } else {
            false
        }
    }

    // - - - - INTERNAL FUNCTIONS - - - -

    fun safety_deposit_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(@0xa)
    }

    // If resolver whitelist contains zero address, then any resolver can fill the order
    fun is_valid_resolver(fusion_order: Object<FusionOrder>, resolver: address): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        vector::contains(&fusion_order_ref.resolver_whitelist, &@0x0) || vector::contains(&fusion_order_ref.resolver_whitelist, &resolver)
    }

    // - - - - BORROW FUNCTIONS - - - -

    /// Borrows an immutable reference to the FusionOrder.
    ///
    /// @param fusion_order_obj The fusion order object.
    /// @return &FusionOrder Immutable reference to the fusion order.
    inline fun borrow_fusion_order(
        fusion_order_obj: &Object<FusionOrder>
    ): &FusionOrder acquires FusionOrder {
        borrow_global<FusionOrder>(object::object_address(fusion_order_obj))
    }

    /// Borrows a mutable reference to the FusionOrder.
    ///
    /// @param fusion_order_obj The fusion order object.
    /// @return &mut FusionOrder Mutable reference to the fusion order.
    inline fun borrow_fusion_order_mut(
        fusion_order_obj: &Object<FusionOrder>
    ): &mut FusionOrder acquires FusionOrder {
        borrow_global_mut<FusionOrder>(object::object_address(fusion_order_obj))
    }

    /// Borrows a mutable reference to the FusionOrderController.
    ///
    /// @param fusion_order_obj The fusion order object.
    /// @return &FusionOrderController Mutable reference to the controller.
    inline fun borrow_fusion_order_controller_mut(
        fusion_order_obj: &Object<FusionOrder>
    ): &FusionOrderController acquires FusionOrderController {
        borrow_global_mut<FusionOrderController>(object::object_address(fusion_order_obj))
    }

    // - - - - TEST FUNCTIONS - - - -

    #[test_only]
    friend fusion_plus::fusion_order_tests;

    #[test_only]
    /// Deletes a fusion order for testing purposes.
    /// Burns the assets instead of returning them to simulate order pickup.
    ///
    /// @param fusion_order The fusion order to delete.
    public fun delete_for_test(
        fusion_order: Object<FusionOrder>
    ) acquires FusionOrder, FusionOrderController {
        let object_address = object::object_address(&fusion_order);
        let FusionOrderController { extend_ref, delete_ref } = move_from(object_address);
        let object_signer = object::generate_signer_for_extending(&extend_ref);

        let fusion_order_ref = borrow_fusion_order_mut(&fusion_order);

        let burn_address = @0x0;
        primary_fungible_store::transfer(
            &object_signer,
            fusion_order_ref.metadata,
            burn_address,
            fusion_order_ref.amount
        );

        primary_fungible_store::transfer(
            &object_signer,
            safety_deposit_metadata(),
            burn_address,
            fusion_order_ref.safety_deposit_amount
        );
        object::delete(delete_ref);
    }
}
