module fusion_plus::router {
    use fusion_plus::dutch_auction::{Self, DutchAuction};
    use fusion_plus::fusion_order::{Self, FusionOrder};
    use aptos_framework::fungible_asset::{Metadata};
    use fusion_plus::escrow;
    use aptos_framework::object::{Object};
    use aptos_framework::signer;
    use std::option::{Self, Option};

    // - - - - DUTCH AUCTION FUNCTIONS - - - -

    /// Entry function for creating a new Dutch auction.
    public entry fun create_auction(
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
        dutch_auction::new(
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

    /// Entry function for cancelling a Dutch auction.
    public entry fun cancel_auction(
        signer: &signer,
        auction: Object<DutchAuction>
    ) {
        dutch_auction::cancel_auction(signer, auction);
    }

    // - - - - FUSION ORDER FUNCTIONS - - - -

    /// Entry function for creating a new FusionOrder.
    public entry fun create_fusion_order(
        signer: &signer,
        order_hash: vector<u8>,
        hashes: vector<vector<u8>>,
        metadata: Object<Metadata>,
        amount: u64,
        safety_deposit_amount: u64,
        resolver_whitelist: vector<address>,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64,
        auto_cancel_after: Option<u64>
    ) {
        fusion_order::new(
            signer,
            order_hash,
            hashes,
            metadata,
            amount,
            resolver_whitelist,
            safety_deposit_amount,
            finality_duration,
            exclusive_duration,
            private_cancellation_duration,
            auto_cancel_after
        );
    }

    /// Entry function for cancelling a FusionOrder.
    public entry fun cancel_fusion_order(
        signer: &signer, fusion_order: Object<FusionOrder>
    ) {
        fusion_order::cancel(signer, fusion_order);
    }

    // - - - - ESCROW FUNCTIONS - - - -

    public entry fun deploy_source_single_fill(
        resolver: &signer, fusion_order: Object<FusionOrder>
    ) {
        escrow::deploy_source(resolver, fusion_order, option::none());
    }

    public entry fun deploy_source_partial_fill(
        resolver: &signer, fusion_order: Object<FusionOrder>, segment: u64
    ) {
        escrow::deploy_source(resolver, fusion_order, option::some(segment));
    }


    public entry fun deploy_destination_single_fill(
        resolver: &signer,
        auction: Object<DutchAuction>,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64
    ) {
        escrow::deploy_destination(
            resolver,
            auction,
            option::none(),
            finality_duration,
            exclusive_duration,
            private_cancellation_duration
        );
    }

    public entry fun deploy_destination_partial_fill(
        resolver: &signer,
        auction: Object<DutchAuction>,
        segment: u64,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64
    ) {
        escrow::deploy_destination(
            resolver,
            auction,
            option::some(segment),
            finality_duration,
            exclusive_duration,
            private_cancellation_duration
        );
    }

}
