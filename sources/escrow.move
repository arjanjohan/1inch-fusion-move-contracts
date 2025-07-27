module fusion_plus::escrow {
    use std::signer;
    use aptos_framework::event::{Self};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef, ObjectGroup};
    use aptos_framework::primary_fungible_store;

    use fusion_plus::hashlock::{Self, HashLock};
    use fusion_plus::timelock::{Self, Timelock};
    use fusion_plus::constants;
    use fusion_plus::fusion_order::{Self, FusionOrder};

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

    // - - - - EVENTS - - - -

    #[event]
    /// Event emitted when an escrow is created
    struct EscrowCreatedEvent has drop, store {
        escrow: Object<Escrow>,
        from: address,
        to: address,
        resolver: address,
        metadata: Object<Metadata>,
        amount: u64,
        chain_id: u64,
        is_source_chain: bool
    }

    #[event]
    /// Event emitted when an escrow is withdrawn by the recipient
    struct EscrowWithdrawnEvent has drop, store {
        escrow: Object<Escrow>,
        recipient: address,
        resolver: address,
        metadata: Object<Metadata>,
        amount: u64
    }

    #[event]
    /// Event emitted when an escrow is recovered/cancelled
    struct EscrowRecoveredEvent has drop, store {
        escrow: Object<Escrow>,
        recovered_by: address,
        returned_to: address,
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
    /// @param metadata The metadata of the asset.
    /// @param amount The amount of the asset being escrowed.
    /// @param from The address that created the escrow (source).
    /// @param to The address that can withdraw the escrow (destination).
    /// @param resolver The resolver address managing this escrow.
    /// @param chain_id Chain ID where this asset originated.
    /// @param timelock The timelock controlling the asset phases.
    /// @param hashlock The hashlock protecting the asset.
    struct Escrow has key, store {
        metadata: Object<Metadata>,
        amount: u64,
        from: address,
        to: address,
        resolver: address,
        chain_id: u64,
        timelock: Timelock,
        hashlock: HashLock
    }

    // - - - - PUBLIC FUNCTIONS - - - -

    /// Creates a new Escrow from a fusion order.
    /// This function is called when a resolver picks up a fusion order.
    ///
    /// @param resolver The signer of the resolver accepting the order.
    /// @param fusion_order The fusion order to convert to escrow.
    ///
    /// @return Object<Escrow> The created escrow object.
    public fun new_from_order(
        resolver: &signer, fusion_order: Object<FusionOrder>
    ): Object<Escrow> {
        let owner_address = fusion_order::get_owner(fusion_order);
        let resolver_address = signer::address_of(resolver);
        let chain_id = fusion_order::get_chain_id(fusion_order);
        let hash = fusion_order::get_hash(fusion_order);
        let (asset, safety_deposit_asset) =
            fusion_order::resolver_accept_order(resolver, fusion_order);
        new_internal(
            resolver,
            asset,
            safety_deposit_asset,
            owner_address, //from
            resolver_address, //to
            resolver_address, //resolver
            chain_id,
            hash
        )
    }

    /// Creates a new Escrow directly from a resolver.
    /// This function is called when a resolver creates an escrow without a fusion order.
    ///
    /// @param resolver The signer of the resolver creating the escrow.
    /// @param recipient_address The address that can withdraw the escrow.
    /// @param metadata The metadata of the asset being escrowed.
    /// @param amount The amount of the asset being escrowed.
    /// @param chain_id The chain ID where this asset originated.
    /// @param hash The hash of the secret for the cross-chain swap.
    ///
    /// @reverts EINVALID_AMOUNT if amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if resolver has insufficient balance.
    /// @return Object<Escrow> The created escrow object.
    public fun new_from_resolver(
        resolver: &signer,
        recipient_address: address,
        metadata: Object<Metadata>,
        amount: u64,
        chain_id: u64,
        hash: vector<u8>
    ): Object<Escrow> {
        let resolver_address = signer::address_of(resolver);

        // Validate inputs
        assert!(amount > 0, EINVALID_AMOUNT);
        assert!(hashlock::is_valid_hash(&hash), EINVALID_SECRET);

        let asset = primary_fungible_store::withdraw(resolver, metadata, amount);

        let safety_deposit_asset =
            primary_fungible_store::withdraw(
                resolver,
                constants::get_safety_deposit_metadata(),
                constants::get_safety_deposit_amount()
            );
        new_internal(
            resolver,
            asset,
            safety_deposit_asset,
            resolver_address, // from
            recipient_address, // to
            resolver_address, // resolver
            chain_id,
            hash
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
    /// @param chain_id The chain ID where this asset originated.
    /// @param hash The hash of the secret for the cross-chain swap.
    ///
    /// @return Object<Escrow> The created escrow object.
    fun new_internal(
        signer: &signer,
        asset: FungibleAsset,
        safety_deposit_asset: FungibleAsset,
        from: address,
        to: address,
        resolver: address,
        chain_id: u64,
        hash: vector<u8>
    ): Object<Escrow> {

        // Create the object and Escrow
        let constructor_ref = object::create_object_from_account(signer);
        let object_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Create the controller
        move_to(
            &object_signer,
            EscrowController { extend_ref, delete_ref }
        );

        let timelock = timelock::new();
        let hashlock = hashlock::create_hashlock(hash);

        let metadata = fungible_asset::metadata_from_asset(&asset);
        let amount = fungible_asset::amount(&asset);

        // Create the Escrow
        let escrow_obj = Escrow {
            metadata,
            amount,
            from,
            to,
            resolver,
            chain_id,
            timelock,
            hashlock
        };

        move_to(&object_signer, escrow_obj);

        let object_address = signer::address_of(&object_signer);

        // Store the asset in the escrow primary store
        primary_fungible_store::ensure_primary_store_exists(object_address, metadata);
        primary_fungible_store::deposit(object_address, asset);

        primary_fungible_store::deposit(object_address, safety_deposit_asset);

        let escrow = object::object_from_constructor_ref(&constructor_ref);

        // Determine if this is on source chain (resolver == to)
        let is_source_chain = resolver == to;

        // Emit creation event
        event::emit(
            EscrowCreatedEvent {
                escrow,
                from,
                to,
                resolver,
                metadata,
                amount,
                chain_id,
                is_source_chain
            }
        );

        escrow
    }

    /// Withdraws assets from an escrow using the correct secret.
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
    public entry fun withdraw(signer: &signer, escrow: Object<Escrow>, secret: vector<u8>) acquires Escrow, EscrowController {
        let signer_address = signer::address_of(signer);

        assert!(escrow_exists(escrow), EOBJECT_DOES_NOT_EXIST);

        let escrow_ref = borrow_escrow_mut(&escrow);
        assert!(escrow_ref.resolver == signer_address, EINVALID_CALLER);

        let timelock = escrow_ref.timelock;
        assert!(timelock::is_in_exclusive_phase(&timelock), EINVALID_PHASE);

        // Verify the secret matches the hashlock
        assert!(hashlock::verify_hashlock(&escrow_ref.hashlock, secret), EINVALID_SECRET);

        let escrow_address = object::object_address(&escrow);
        let EscrowController { extend_ref, delete_ref } =
            move_from(escrow_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Store event data before deletion
        let recipient = escrow_ref.to;
        let metadata = escrow_ref.metadata;
        let amount = escrow_ref.amount;

        primary_fungible_store::transfer(
            &object_signer,
            escrow_ref.metadata,
            escrow_ref.to,
            escrow_ref.amount
        );

        primary_fungible_store::transfer(
            &object_signer,
            constants::get_safety_deposit_metadata(),
            signer_address,
            constants::get_safety_deposit_amount()
        );

        object::delete(delete_ref);

        // Emit withdrawal event
        event::emit(
            EscrowWithdrawnEvent {
                escrow,
                recipient,
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
    public entry fun recovery(signer: &signer, escrow: Object<Escrow>) acquires Escrow, EscrowController {
        let signer_address = signer::address_of(signer);

        assert!(escrow_exists(escrow), EOBJECT_DOES_NOT_EXIST);

        let escrow_ref = borrow_escrow_mut(&escrow);
        let timelock = escrow_ref.timelock;

        if (timelock::is_in_private_cancellation_phase(&timelock)) {
            assert!(escrow_ref.resolver == signer_address, EINVALID_CALLER);
        } else {
            assert!(timelock::is_in_public_cancellation_phase(&timelock), EINVALID_PHASE);
        };

        let escrow_address = object::object_address(&escrow);
        let EscrowController { extend_ref, delete_ref } =
            move_from(escrow_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Store event data before deletion
        let recovered_by = signer_address;
        let returned_to = escrow_ref.from;
        let metadata = escrow_ref.metadata;
        let amount = escrow_ref.amount;

        primary_fungible_store::transfer(
            &object_signer,
            escrow_ref.metadata,
            escrow_ref.from,
            escrow_ref.amount
        );

        primary_fungible_store::transfer(
            &object_signer,
            constants::get_safety_deposit_metadata(),
            signer_address,
            constants::get_safety_deposit_amount()
        );

        object::delete(delete_ref);

        // Emit recovery event
        event::emit(
            EscrowRecoveredEvent {
                escrow,
                recovered_by,
                returned_to,
                metadata,
                amount
            }
        );
    }

    // - - - - GETTER FUNCTIONS - - - -

    /// Gets the metadata of the asset in an escrow.
    ///
    /// @param escrow The escrow to get the metadata from.
    /// @return Object<Metadata> The metadata of the asset.
    public fun get_metadata(escrow: Object<Escrow>): Object<Metadata> acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.metadata
    }

    /// Gets the amount of the asset in an escrow.
    ///
    /// @param escrow The escrow to get the amount from.
    /// @return u64 The amount of the asset.
    public fun get_amount(escrow: Object<Escrow>): u64 acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.amount
    }

    /// Gets the 'from' address of an escrow.
    ///
    /// @param escrow The escrow to get the 'from' address from.
    /// @return address The address that created the escrow.
    public fun get_from(escrow: Object<Escrow>): address acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.from
    }

    /// Gets the 'to' address of an escrow.
    ///
    /// @param escrow The escrow to get the 'to' address from.
    /// @return address The address that can withdraw the escrow.
    public fun get_to(escrow: Object<Escrow>): address acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.to
    }

    /// Gets the resolver address of an escrow.
    ///
    /// @param escrow The escrow to get the resolver from.
    /// @return address The resolver address.
    public fun get_resolver(escrow: Object<Escrow>): address acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.resolver
    }

    /// Gets the chain ID of an escrow.
    ///
    /// @param escrow The escrow to get the chain ID from.
    /// @return u64 The chain ID.
    public fun get_chain_id(escrow: Object<Escrow>): u64 acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.chain_id
    }

    /// Gets the timelock of an escrow.
    ///
    /// @param escrow The escrow to get the timelock from.
    /// @return Timelock The timelock object.
    public fun get_timelock(escrow: Object<Escrow>): Timelock acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.timelock
    }

    /// Gets the hashlock of an escrow.
    ///
    /// @param escrow The escrow to get the hashlock from.
    /// @return HashLock The hashlock object.
    public fun get_hashlock(escrow: Object<Escrow>): HashLock acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.hashlock
    }

    /// Checks if an escrow is on the source chain.
    ///
    /// @param escrow The escrow to check.
    /// @return bool True if the escrow is on the source chain, false otherwise.
    public fun is_source_chain(escrow: Object<Escrow>): bool acquires Escrow {
        let escrow_ref = borrow_escrow(&escrow);
        escrow_ref.to == escrow_ref.resolver
    }

    // - - - - UTILITY FUNCTIONS - - - -

    /// Checks if an escrow exists.
    ///
    /// @param escrow The escrow object to check.
    /// @return bool True if the escrow exists, false otherwise.
    public fun escrow_exists(escrow: Object<Escrow>): bool {
        object::object_exists<Escrow>(object::object_address(&escrow))
    }


    // - - - - BORROW FUNCTIONS - - - -

    /// Borrows an immutable reference to the Escrow.
    ///
    /// @param escrow_obj The escrow object.
    /// @return &Escrow Immutable reference to the escrow.
    inline fun borrow_escrow(
        escrow_obj: &Object<Escrow>
    ): &Escrow acquires Escrow {
        borrow_global<Escrow>(object::object_address(escrow_obj))
    }

    /// Borrows a mutable reference to the Escrow.
    ///
    /// @param escrow_obj The escrow object.
    /// @return &mut Escrow Mutable reference to the escrow.
    inline fun borrow_escrow_mut(
        escrow_obj: &Object<Escrow>
    ): &mut Escrow acquires Escrow {
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
