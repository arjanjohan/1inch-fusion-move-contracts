module fusion_plus::escrow {
    use std::signer;
    use std::option::{Self, Option};
    use aptos_framework::event::{Self};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef, ObjectGroup};
    use aptos_framework::primary_fungible_store;

    use fusion_plus::hashlock::{Self, HashLock};
    use fusion_plus::timelock::{Self, Timelock};
    use fusion_plus::fusion_order::{Self, FusionOrder};
    use fusion_plus::dutch_auction::{Self, DutchAuction};
    // use std::vector;

    // - - - - ERROR CODES - - - -

    /// Invalid phase
    const EINVALID_PHASE: u64 = 1;
    /// Invalid caller
    const EINVALID_CALLER: u64 = 2;
    /// Invalid secret
    const EINVALID_SECRET: u64 = 3;
    /// Invalid amount
    const EINVALID_AMOUNT: u64 = 4;
    /// Object does not exist
    const EOBJECT_DOES_NOT_EXIST: u64 = 5;
    /// Invalid hash.
    const EINVALID_HASH: u64 = 6;
    /// Invalid fill type
    const EINVALID_FILL_TYPE: u64 = 7;
    /// Insufficient remaining amount
    const EINSUFFICIENT_REMAINING: u64 = 8;
    /// Invalid segment
    const EINVALID_SEGMENT: u64 = 9;

    // - - - - EVENTS - - - -

    #[event]
    /// Event emitted when an escrow is created
    struct EscrowCreatedEvent has drop, store {
        order_hash: vector<u8>,
        escrow: Object<Escrow>,
        maker: address,
        taker: address,
        metadata: Object<Metadata>,
        amount: u64,
        safety_deposit_amount: u64,
        is_source_chain: bool
    }

    #[event]
    /// Event emitted when an escrow is withdrawn by the recipient
    struct EscrowWithdrawnEvent has drop, store {
        escrow: Object<Escrow>,
        withdraw_to: address,
        resolver: address,
        metadata: Object<Metadata>,
        amount: u64
    }

    #[event]
    /// Event emitted when an escrow is recovered/cancelled
    struct EscrowRecoveredEvent has drop, store {
        escrow: Object<Escrow>,
        recover_to: address,
        resolver: address,
        metadata: Object<Metadata>,
        amount: u64
    }

    // - - - - STRUCTS - - - -

    #[resource_group_member(group = ObjectGroup)]
    /// Controller for managing the lifecycle of an Escrow.
    ///
    /// @param extend_ref The extend_ref of the escrow, used to generate signer for the escrow.
    /// @param delete_ref The delete ref of the escrow, used to delete the escrow.
    struct EscrowController has key {
        extend_ref: ExtendRef,
        delete_ref: DeleteRef
    }

    /// An Escrow Object that contains the assets that are being escrowed.
    /// The object can be stored in other structs because it has the `store` ability.
    ///
    struct Escrow has key, store {
        order_hash: vector<u8>,
        metadata: Object<Metadata>,
        amount: u64,
        safety_deposit_amount: u64,
        maker: address,
        taker: address,
        is_source_chain: bool,
        timelock: Timelock,
        hashlock: HashLock
    }

    // - - - - PUBLIC FUNCTIONS - - - -

    /// Creates a new Escrow from a fusion order.
    /// This function is called when a resolver picks up a fusion order.
    /// If fill_amount is None, the entire order is filled. Otherwise, only the specified amount is filled.
    ///
    /// @param resolver The signer of the resolver accepting the order.
    /// @param fusion_order The fusion order to convert to escrow.
    /// @param fill_amount The amount to fill (None for full fill).
    ///
    /// @return Object<Escrow> The created escrow object.
    public fun deploy_source(
        resolver: &signer, fusion_order: Object<FusionOrder>, segment: Option<u64>
    ): Object<Escrow> {

        let segment_hash =
            if (option::is_some(&segment)) {
                fusion_order::get_hash_for_segment(
                    fusion_order, *option::borrow(&segment)
                )
            } else {
                // Use last hash for full fill
                fusion_order::get_hash_for_segment(
                    fusion_order, fusion_order::get_max_segments(fusion_order) - 1
                )
            };
        if (option::is_some(&segment)) {
            // Validate partial fill is allowed
            assert!(
                fusion_order::is_partial_fill_allowed(fusion_order),
                EINVALID_FILL_TYPE
            );

            let max_segments = fusion_order::get_max_segments(fusion_order);
            assert!(*option::borrow(&segment) < max_segments, EINVALID_SEGMENT);
        };

        let (asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(resolver, fusion_order, segment);

        new(
            resolver,
            fusion_order::get_order_hash(fusion_order),
            asset,
            safety_deposit_asset,
            fusion_order::get_maker(fusion_order), // maker
            signer::address_of(resolver), // taker
            true, // is_source_chain
            segment_hash,
            fusion_order::get_finality_duration(fusion_order),
            fusion_order::get_exclusive_duration(fusion_order),
            fusion_order::get_private_cancellation_duration(fusion_order)
        )
    }

    /// Creates a new Escrow using a Dutch auction for partial fills.
    /// This function is called when a resolver creates a partial escrow for an ETH > APT order.
    /// The amount is determined by the segment and current auction price.
    ///
    /// @param resolver The signer of the resolver creating the escrow.
    /// @param auction The Dutch auction that determines the price.
    /// @param segment The segment to fill (0-9 for partial fills, 10 for full fill).
    /// @param safety_deposit_amount The amount of safety deposit required.
    /// @param finality_duration The finality duration for the escrow.
    /// @param exclusive_duration The exclusive duration for the escrow.
    /// @param private_cancellation_duration The private cancellation duration for the escrow.
    ///
    /// @reverts EINVALID_AMOUNT if auction price is zero.
    /// @reverts EINSUFFICIENT_BALANCE if resolver has insufficient balance.
    /// @reverts EINVALID_FILL_TYPE if partial fills are not allowed.
    /// @reverts EINVALID_SEGMENT if segment is invalid.
    /// @return Object<Escrow> The created escrow object.
    public fun deploy_destination(
        resolver: &signer,
        auction: Object<DutchAuction>,
        segment: Option<u64>,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64
    ): Object<Escrow> {

        // Validate partial fill is allowed
        if (option::is_some(&segment)) {
            assert!(
                dutch_auction::is_partial_fill_allowed(auction), EINVALID_FILL_TYPE
            );
        };

        // Validate segment is valid (last segment is full fill)
        let max_segments = dutch_auction::get_max_segments(auction);
        let segment = *option::borrow_with_default(&segment, &(max_segments - 1));
        assert!(segment < max_segments, EINVALID_SEGMENT);

        // Fill the auction and get assets (this handles all validation and withdrawal)
        let (asset, safety_deposit_asset) =
            dutch_auction::fill_auction(resolver, auction, option::some<u64>(segment));

        // Get auction details
        let order_hash = dutch_auction::get_order_hash(auction);
        let maker = dutch_auction::get_maker(auction);

        // Get the segment hash for this partial fill
        let segment_hash = dutch_auction::get_segment_hash(auction, segment);

        // Create escrow with the assets from the auction
        new(
            resolver,
            order_hash,
            asset,
            safety_deposit_asset,
            maker, // maker (from auction)
            signer::address_of(resolver), // taker (resolver)
            false, // is_source_chain
            segment_hash, // Use the segment hash for this partial fill
            finality_duration,
            exclusive_duration,
            private_cancellation_duration
        )
    }

    /// Internal function to create a new Escrow with the specified parameters.
    ///
    /// @param signer The signer creating the escrow.
    /// @param asset The fungible asset to escrow.
    /// @param safety_deposit_asset The safety deposit asset.
    /// @param from The address that created the escrow.
    /// @param to The address that can withdraw the escrow.
    /// @param resolver The resolver address managing this escrow.
    /// @param hash The hash of the secret for the cross-chain swap.
    ///
    /// @return Object<Escrow> The created escrow object.
    fun new(
        resolver: &signer,
        order_hash: vector<u8>,
        asset: FungibleAsset,
        safety_deposit_asset: FungibleAsset,
        maker: address,
        taker: address,
        is_source_chain: bool,
        hash: vector<u8>,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64
    ): Object<Escrow> {

        // Create the object and Escrow
        let constructor_ref = object::create_object_from_account(resolver);
        let object_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Create the controller
        move_to(
            &object_signer,
            EscrowController { extend_ref, delete_ref }
        );

        let timelock =
            timelock::new_from_durations(
                finality_duration, exclusive_duration, private_cancellation_duration
            );
        let hashlock = hashlock::create_hashlock(hash);

        let metadata = fungible_asset::metadata_from_asset(&asset);
        let amount = fungible_asset::amount(&asset);
        let safety_deposit_amount = fungible_asset::amount(&safety_deposit_asset);

        // Create the Escrow
        let escrow_obj = Escrow {
            order_hash,
            metadata,
            amount,
            safety_deposit_amount,
            maker,
            taker,
            is_source_chain,
            timelock,
            hashlock
        };

        move_to(&object_signer, escrow_obj);

        let object_address = signer::address_of(&object_signer);

        // Store the asset in the escrow primary store
        primary_fungible_store::ensure_primary_store_exists(object_address, metadata);

        // TODO: Merge if asset is native token
        primary_fungible_store::deposit(object_address, safety_deposit_asset);
        primary_fungible_store::deposit(object_address, asset);

        let escrow = object::object_from_constructor_ref(&constructor_ref);

        // Emit creation event
        event::emit(
            EscrowCreatedEvent {
                order_hash,
                escrow,
                maker,
                taker,
                metadata,
                amount,
                safety_deposit_amount,
                is_source_chain
            }
        );

        escrow
    }

    /// Withdraws assets from an escrow to the taker using the correct secret.
    /// This function can only be called by the resolver during the exclusive phase.
    ///
    /// @param signer The signer of the resolver.
    /// @param escrow The escrow to withdraw from.
    /// @param secret The secret to verify against the hashlock.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the escrow does not exist.
    /// @reverts EINVALID_CALLER if the signer is not the resolver.
    /// @reverts EINVALID_PHASE if not in exclusive phase.
    /// @reverts EINVALID_SECRET if the secret does not match the hashlock.
    public entry fun withdraw(
        signer: &signer, escrow: Object<Escrow>, secret: vector<u8>
    ) acquires Escrow, EscrowController {
        let signer_address = signer::address_of(signer);

        assert!(escrow_exists(escrow), EOBJECT_DOES_NOT_EXIST);

        let escrow_ref = borrow_escrow_mut(&escrow);
        assert!(escrow_ref.taker == signer_address, EINVALID_CALLER);

        let timelock = escrow_ref.timelock;
        assert!(timelock::is_in_exclusive_phase(&timelock), EINVALID_PHASE);

        // Verify the secret matches the hashlock
        assert!(
            hashlock::verify_hashlock(&escrow_ref.hashlock, secret), EINVALID_SECRET
        );

        let escrow_address = object::object_address(&escrow);
        let EscrowController { extend_ref, delete_ref } = move_from(escrow_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        let withdraw_to =
            if (escrow_ref.is_source_chain) {
                escrow_ref.taker
            } else {
                escrow_ref.maker
            };
        let metadata = escrow_ref.metadata;
        let amount = escrow_ref.amount;
        let safety_deposit_amount = escrow_ref.safety_deposit_amount;

        primary_fungible_store::transfer(&object_signer, metadata, withdraw_to, amount);

        primary_fungible_store::transfer(
            &object_signer,
            object::address_to_object<Metadata>(@0xa),
            signer_address,
            safety_deposit_amount
        );

        object::delete(delete_ref);

        // Emit withdrawal event
        event::emit(
            EscrowWithdrawnEvent {
                escrow,
                withdraw_to,
                resolver: signer_address,
                metadata,
                amount
            }
        );
    }

    /// Recovers assets from an escrow during cancellation phases.
    /// This function can be called by the resolver during private cancellation phase
    /// or by anyone during public cancellation phase.
    ///
    /// @param signer The signer attempting to recover the escrow.
    /// @param escrow The escrow to recover from.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the escrow does not exist.
    /// @reverts EINVALID_CALLER if the signer is not the resolver during private cancellation.
    /// @reverts EINVALID_PHASE if not in cancellation phase.
    public entry fun recovery(
        signer: &signer, escrow: Object<Escrow>
    ) acquires Escrow, EscrowController {
        let signer_address = signer::address_of(signer);

        assert!(escrow_exists(escrow), EOBJECT_DOES_NOT_EXIST);

        let escrow_ref = borrow_escrow_mut(&escrow);
        let timelock = escrow_ref.timelock;

        if (timelock::is_in_private_cancellation_phase(&timelock)) {
            assert!(escrow_ref.taker == signer_address, EINVALID_CALLER);
        } else {
            assert!(
                timelock::is_in_public_cancellation_phase(&timelock), EINVALID_PHASE
            );
        };

        let escrow_address = object::object_address(&escrow);
        let EscrowController { extend_ref, delete_ref } = move_from(escrow_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Store event data before deletion
        let resolver = signer_address;
        let recover_to =
            if (escrow_ref.is_source_chain) {
                escrow_ref.maker
            } else {
                escrow_ref.taker
            };
        let metadata = escrow_ref.metadata;
        let amount = escrow_ref.amount;

        primary_fungible_store::transfer(
            &object_signer,
            escrow_ref.metadata,
            recover_to,
            escrow_ref.amount
        );

        primary_fungible_store::transfer(
            &object_signer,
            object::address_to_object<Metadata>(@0xa),
            signer_address,
            escrow_ref.safety_deposit_amount
        );

        object::delete(delete_ref);

        // Emit recovery event
        event::emit(
            EscrowRecoveredEvent { escrow, recover_to, resolver, metadata, amount }
        );
    }

    // - - - - VIEW FUNCTIONS - - - -

    #[view]
    /// Gets the order hash of an escrow.
    ///
    /// @param escrow The escrow to get the order hash from.
    /// @return vector<u8> The order hash.
    public fun get_order_hash(escrow: Object<Escrow>): vector<u8> acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.order_hash
    }

    #[view]
    /// Gets the metadata of the asset in an escrow.
    ///
    /// @param escrow The escrow to get the metadata from.
    /// @return Object<Metadata> The metadata of the asset.
    public fun get_metadata(escrow: Object<Escrow>): Object<Metadata> acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.metadata
    }

    #[view]
    /// Gets the amount of the asset in an escrow.
    ///
    /// @param escrow The escrow to get the amount from.
    /// @return u64 The amount of the asset.
    public fun get_amount(escrow: Object<Escrow>): u64 acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.amount
    }

    #[view]
    /// Gets the safety deposit amount of an escrow.
    ///
    /// @param escrow The escrow to get the safety deposit amount from.
    /// @return u64 The safety deposit amount.
    public fun get_safety_deposit_amount(escrow: Object<Escrow>): u64 acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.safety_deposit_amount
    }

    #[view]
    /// Gets the maker address of an escrow.
    ///
    /// @param escrow The escrow to get the maker address from.
    /// @return address The address that created the escrow.
    public fun get_maker(escrow: Object<Escrow>): address acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.maker
    }

    #[view]
    /// Gets the taker address of an escrow.
    ///
    /// @param escrow The escrow to get the taker address from.
    /// @return address The address that can withdraw the escrow.
    public fun get_taker(escrow: Object<Escrow>): address acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.taker
    }

    #[view]
    /// Gets the timelock of an escrow.
    ///
    /// @param escrow The escrow to get the timelock from.
    /// @return Timelock The timelock object.
    public fun get_timelock(escrow: Object<Escrow>): Timelock acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.timelock
    }

    #[view]
    /// Gets the hashlock of an escrow.
    ///
    /// @param escrow The escrow to get the hashlock from.
    /// @return HashLock The hashlock object.
    public fun get_hashlock(escrow: Object<Escrow>): HashLock acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.hashlock
    }

    #[view]
    /// Gets the hash of an escrow.
    ///
    /// @param escrow The escrow to get the hash from.
    /// @return vector<u8> The hash.
    public fun get_hash(escrow: Object<Escrow>): vector<u8> acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        hashlock::get_hash(&escrow_ref.hashlock)
    }

    #[view]
    /// Checks if an escrow is on the source chain.
    ///
    /// @param escrow The escrow to check.
    /// @return bool True if the escrow is on the source chain, false otherwise.
    public fun is_source_chain(escrow: Object<Escrow>): bool acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.is_source_chain
    }

    #[view]
    /// Gets the finality duration of an escrow.
    ///
    /// @param escrow The escrow to get the finality duration from.
    /// @return u64 The finality duration.
    public fun get_finality_duration(escrow: Object<Escrow>): u64 acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        timelock::get_finality_duration(&escrow_ref.timelock)
    }

    #[view]
    /// Gets the exclusive duration of an escrow.
    ///
    /// @param escrow The escrow to get the exclusive duration from.
    /// @return u64 The exclusive duration.
    public fun get_exclusive_duration(escrow: Object<Escrow>): u64 acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        timelock::get_exclusive_duration(&escrow_ref.timelock)
    }

    #[view]
    /// Gets the private cancellation duration of an escrow.
    ///
    /// @param escrow The escrow to get the private cancellation duration from.
    /// @return u64 The private cancellation duration.
    public fun get_private_cancellation_duration(escrow: Object<Escrow>): u64 acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        timelock::get_private_cancellation_duration(&escrow_ref.timelock)
    }

    #[view]
    /// Test function to verify a secret against the hashlock.
    ///
    /// @param escrow The escrow to verify the secret against.
    /// @param secret The secret to verify.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the escrow does not exist.
    /// @return bool True if the secret matches the hashlock, false otherwise.
    public fun verify_secret(escrow: Object<Escrow>, secret: vector<u8>): bool acquires Escrow {
        assert!(escrow_exists(escrow), EOBJECT_DOES_NOT_EXIST);
        let escrow_ref = borrow_escrow(&escrow);

        hashlock::verify_hashlock(&escrow_ref.hashlock, secret)
    }

    // - - - - UTILITY FUNCTIONS - - - -

    /// Checks if an escrow exists.
    ///
    /// @param escrow The escrow object to check.
    /// @return bool True if the escrow exists, false otherwise.
    public fun escrow_exists(escrow: Object<Escrow>): bool {
        object::object_exists<Escrow>(object::object_address(&escrow))
    }

    // - - - - INTERNAL FUNCTIONS - - - -

    fun safety_deposit_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(@0xa)
    }

    // - - - - BORROW FUNCTIONS - - - -

    /// Borrows an immutable reference to the Escrow.
    ///
    /// @param escrow_obj The escrow object.
    /// @return &Escrow Immutable reference to the escrow.
    inline fun borrow_escrow(escrow_obj: &Object<Escrow>): &Escrow acquires Escrow {
        borrow_global<Escrow>(object::object_address(escrow_obj))
    }

    /// Borrows a mutable reference to the Escrow.
    ///
    /// @param escrow_obj The escrow object.
    /// @return &mut Escrow Mutable reference to the escrow.
    inline fun borrow_escrow_mut(escrow_obj: &Object<Escrow>): &mut Escrow acquires Escrow {
        borrow_global_mut<Escrow>(object::object_address(escrow_obj))
    }

    /// Borrows an immutable reference to the EscrowController.
    ///
    /// @param escrow_obj The escrow object.
    /// @return &EscrowController Immutable reference to the controller.
    inline fun borrow_escrow_controller(
        escrow_obj: &Object<Escrow>
    ): &EscrowController acquires EscrowController {
        borrow_global<EscrowController>(object::object_address(escrow_obj))
    }

    /// Borrows a mutable reference to the EscrowController.
    ///
    /// @param escrow_obj The escrow object.
    /// @return &mut EscrowController Mutable reference to the controller.
    inline fun borrow_escrow_controller_mut(
        escrow_obj: &Object<Escrow>
    ): &mut EscrowController acquires EscrowController {
        borrow_global_mut<EscrowController>(object::object_address(escrow_obj))
    }
}
