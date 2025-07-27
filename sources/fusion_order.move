module fusion_plus::fusion_order {
    use std::signer;
    use aptos_framework::event::{Self};
    use aptos_framework::fungible_asset::{FungibleAsset, Metadata};
    use aptos_framework::object::{Self, Object, ExtendRef, DeleteRef, ObjectGroup};
    use aptos_framework::primary_fungible_store;

    use fusion_plus::constants;
    use fusion_plus::resolver_registry;

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

    // - - - - EVENTS - - - -

    #[event]
    /// Event emitted when a fusion order is created
    struct FusionOrderCreatedEvent has drop, store {
        fusion_order: Object<FusionOrder>,
        owner: address,
        metadata: Object<Metadata>,
        amount: u64,
        chain_id: u64
    }

    #[event]
    /// Event emitted when a fusion order is cancelled by the owner
    struct FusionOrderCancelledEvent has drop, store {
        fusion_order: Object<FusionOrder>,
        owner: address,
        metadata: Object<Metadata>,
        amount: u64
    }

    #[event]
    /// Event emitted when a fusion order is accepted by a resolver
    struct FusionOrderAcceptedEvent has drop, store {
        fusion_order: Object<FusionOrder>,
        resolver: address,
        owner: address,
        metadata: Object<Metadata>,
        amount: u64,
        chain_id: u64
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
    /// The order can be cancelled by the owner before a resolver picks it up.
    /// Once picked up by a resolver, the order is converted to an escrow.
    ///
    /// @param owner The address of the user who created this order.
    /// @param metadata The metadata of the asset being swapped.
    /// @param amount The amount of the asset being swapped.
    /// @param safety_deposit_metadata The metadata of the safety deposit asset.
    /// @param safety_deposit_amount The amount of safety deposit required.
    /// @param chain_id The destination chain ID for the swap.
    /// @param hash The hash of the secret for the cross-chain swap.
    struct FusionOrder has key, store {
        owner: address,
        metadata: Object<Metadata>,
        amount: u64,
        safety_deposit_metadata: Object<Metadata>,
        safety_deposit_amount: u64,
        chain_id: u64,
        hash: vector<u8>
    }

    // - - - - ENTRY FUNCTIONS - - - -

    /// Entry function for creating a new FusionOrder.
    public entry fun new_entry(
        signer: &signer,
        metadata: Object<Metadata>,
        amount: u64,
        chain_id: u64,
        hash: vector<u8>
    ) {
        new(signer, metadata, amount, chain_id, hash);
    }

    // - - - - PUBLIC FUNCTIONS - - - -

    /// Creates a new FusionOrder with the specified parameters.
    ///
    /// @param signer The signer of the user creating the order.
    /// @param metadata The metadata of the asset being swapped.
    /// @param amount The amount of the asset being swapped.
    /// @param chain_id The destination chain ID for the swap.
    /// @param hash The hash of the secret for the cross-chain swap.
    ///
    /// @reverts EINVALID_AMOUNT if amount or safety deposit amount is zero.
    /// @reverts EINSUFFICIENT_BALANCE if user has insufficient balance for main asset or safety deposit.
    /// @return Object<FusionOrder> The created fusion order object.
    public fun new(
        signer: &signer,
        metadata: Object<Metadata>,
        amount: u64,
        chain_id: u64,
        hash: vector<u8>
    ): Object<FusionOrder> {

        let signer_address = signer::address_of(signer);

        let safety_deposit_metadata = constants::get_safety_deposit_metadata();
        let safety_deposit_amount = constants::get_safety_deposit_amount();

        // Validate inputs
        assert!(amount > 0, EINVALID_AMOUNT);
        assert!(safety_deposit_amount > 0, EINVALID_AMOUNT);
        assert!(is_valid_hash(&hash), EINVALID_HASH);
        assert!(
            primary_fungible_store::balance(signer_address, metadata) >= amount,
            EINSUFFICIENT_BALANCE
        );
        assert!(
            primary_fungible_store::balance(signer_address, safety_deposit_metadata)
                >= safety_deposit_amount,
            EINSUFFICIENT_BALANCE
        );

        // Create an object and FusionOrder
        let constructor_ref = object::create_object_from_account(signer);
        let object_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let delete_ref = object::generate_delete_ref(&constructor_ref);

        // Create the controller
        move_to(
            &object_signer,
            FusionOrderController { extend_ref, delete_ref }
        );

        // Create the FusionOrder
        let fusion_order = FusionOrder {
            owner: signer_address,
            metadata,
            amount,
            safety_deposit_metadata,
            safety_deposit_amount,
            chain_id,
            hash
        };

        move_to(&object_signer, fusion_order);

        let object_address = signer::address_of(&object_signer);

        // Store the asset in the fusion order primary store
        primary_fungible_store::ensure_primary_store_exists(object_address, metadata);
        primary_fungible_store::transfer(signer, metadata, object_address, amount);

        // Transfer the safety deposit amount to fusion order primary store
        primary_fungible_store::transfer(
            signer,
            safety_deposit_metadata,
            object_address,
            safety_deposit_amount
        );

        let fusion_order_obj = object::object_from_constructor_ref(&constructor_ref);

        // Emit creation event
        event::emit(
            FusionOrderCreatedEvent {
                fusion_order: fusion_order_obj,
                owner: signer_address,
                metadata,
                amount,
                chain_id
            }
        );

        fusion_order_obj

    }

    /// Cancels a fusion order and returns assets to the owner. This function can only be called by the owner before it is picked up by a resolver.
    ///
    /// @param signer The signer of the order owner.
    /// @param fusion_order The fusion order to cancel.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the fusion order does not exist.
    /// @reverts EINVALID_CALLER if the signer is not the order owner.
    public entry fun cancel(
        signer: &signer, fusion_order: Object<FusionOrder>
    ) acquires FusionOrder, FusionOrderController {
        let signer_address = signer::address_of(signer);

        assert!(order_exists(fusion_order), EOBJECT_DOES_NOT_EXIST);
        assert!(is_owner(fusion_order, signer_address), EINVALID_CALLER);

        let object_address = object::object_address(&fusion_order);
        let fusion_order_ref = borrow_fusion_order_mut(&fusion_order);
        let controller = borrow_fusion_order_controller_mut(&fusion_order);

        // Store event data before deletion
        let owner = fusion_order_ref.owner;
        let metadata = fusion_order_ref.metadata;
        let amount = fusion_order_ref.amount;

        let FusionOrderController { extend_ref, delete_ref } = move_from(object_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Return main asset to owner
        primary_fungible_store::transfer(
            &object_signer,
            fusion_order_ref.metadata,
            signer_address,
            fusion_order_ref.amount
        );

        // Return safety deposit to owner
        primary_fungible_store::transfer(
            &object_signer,
            fusion_order_ref.safety_deposit_metadata,
            signer_address,
            fusion_order_ref.safety_deposit_amount
        );

        object::delete(delete_ref);

        // Emit cancellation event
        event::emit(
            FusionOrderCancelledEvent {
                fusion_order,
                owner,
                metadata,
                amount
            }
        );

    }

    /// Allows an active resolver to accept a fusion order.
    /// This function is called from the escrow module when creating an escrow from a fusion order.
    ///
    /// @param signer The signer of the resolver accepting the order.
    /// @param fusion_order The fusion order to accept.
    ///
    /// @reverts EOBJECT_DOES_NOT_EXIST if the fusion order does not exist.
    /// @reverts EINVALID_RESOLVER if the signer is not an active resolver.
    /// @return (FungibleAsset, FungibleAsset) The main asset and safety deposit asset.
    public(friend) fun resolver_accept_order(
        signer: &signer, fusion_order: Object<FusionOrder>
    ): (FungibleAsset, FungibleAsset) acquires FusionOrder, FusionOrderController {
        let signer_address = signer::address_of(signer);

        assert!(order_exists(fusion_order), EOBJECT_DOES_NOT_EXIST);
        assert!(
            resolver_registry::is_active_resolver(signer_address), EINVALID_RESOLVER
        );

        let object_address = object::object_address(&fusion_order);
        let fusion_order_ref = borrow_fusion_order_mut(&fusion_order);
        let controller = borrow_fusion_order_controller_mut(&fusion_order);

        // Store event data before deletion
        let owner = fusion_order_ref.owner;
        let metadata = fusion_order_ref.metadata;
        let amount = fusion_order_ref.amount;
        let chain_id = fusion_order_ref.chain_id;

        let FusionOrderController { extend_ref, delete_ref } = move_from(object_address);

        let object_signer = object::generate_signer_for_extending(&extend_ref);

        // Withdraw main asset
        let asset =
            primary_fungible_store::withdraw(
                &object_signer,
                fusion_order_ref.metadata,
                fusion_order_ref.amount
            );

        // Withdraw safety deposit asset
        let safety_deposit_asset =
            primary_fungible_store::withdraw(
                &object_signer,
                constants::get_safety_deposit_metadata(),
                constants::get_safety_deposit_amount()
            );

        object::delete(delete_ref);

        // Emit acceptance event
        event::emit(
            FusionOrderAcceptedEvent {
                fusion_order,
                resolver: signer_address,
                owner,
                metadata,
                amount,
                chain_id
            }
        );

        (asset, safety_deposit_asset)

    }

    // - - - - GETTER FUNCTIONS - - - -

    /// Gets the owner address of a fusion order.
    ///
    /// @param fusion_order The fusion order to get the owner from.
    /// @return address The owner address.
    public fun get_owner(fusion_order: Object<FusionOrder>): address acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.owner
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

    /// Gets the metadata of the safety deposit asset in a fusion order.
    ///
    /// @param fusion_order The fusion order to get the safety deposit metadata from.
    /// @return Object<Metadata> The metadata of the safety deposit asset.
    public fun get_safety_deposit_metadata(
        fusion_order: Object<FusionOrder>
    ): Object<Metadata> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.safety_deposit_metadata
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

    /// Gets the destination chain ID of a fusion order.
    ///
    /// @param fusion_order The fusion order to get the chain ID from.
    /// @return u64 The destination chain ID.
    public fun get_chain_id(fusion_order: Object<FusionOrder>): u64 acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.chain_id
    }

    /// Gets the hash of the secret in a fusion order.
    ///
    /// @param fusion_order The fusion order to get the hash from.
    /// @return vector<u8> The hash of the secret.
    public fun get_hash(fusion_order: Object<FusionOrder>): vector<u8> acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.hash
    }

    /// Checks if a hash value is valid (non-empty).
    ///
    /// @param hash The hash value to check.
    /// @return bool True if the hash is valid, false otherwise.
    public fun is_valid_hash(hash: &vector<u8>): bool {
        std::vector::length(hash) > 0
    }

    /// Checks if a fusion order exists.
    ///
    /// @param fusion_order The fusion order object to check.
    /// @return bool True if the fusion order exists, false otherwise.
    public fun order_exists(fusion_order: Object<FusionOrder>): bool {
        object::object_exists<FusionOrder>(object::object_address(&fusion_order))
    }

    /// Checks if an address is the owner of a fusion order.
    ///
    /// @param fusion_order The fusion order to check.
    /// @param address The address to check against.
    /// @return bool True if the address is the owner, false otherwise.
    public fun is_owner(fusion_order: Object<FusionOrder>, address: address): bool acquires FusionOrder {
        let fusion_order_ref = borrow_fusion_order(&fusion_order);
        fusion_order_ref.owner == address
    }

    // - - - - BORROW FUNCTIONS - - - -

    /// Borrows a mutable reference to the FusionOrderController.
    ///
    /// @param fusion_order_obj The fusion order object.
    /// @return &FusionOrderController Mutable reference to the controller.
    inline fun borrow_fusion_order_controller_mut(
        fusion_order_obj: &Object<FusionOrder>
    ): &FusionOrderController acquires FusionOrderController {
        borrow_global_mut<FusionOrderController>(object::object_address(fusion_order_obj))
    }

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
            fusion_order_ref.safety_deposit_metadata,
            burn_address,
            fusion_order_ref.safety_deposit_amount
        );
        object::delete(delete_ref);
    }
}
