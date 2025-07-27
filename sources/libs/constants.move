module fusion_plus::constants {

    use aptos_framework::fungible_asset::{Metadata};
    use aptos_framework::object::{Self, Object};


    // - - - - CONSTANTS - - - -

    const DEFAULT_SAFETY_DEPOSIT_METADATA_ADDRESS: address = @0xa;
    const DEFAULT_SAFETY_DEPOSIT_AMOUNT: u64 = 100_000;

    const DEFAULT_FINALITY_DURATION: u64 = 10; // 10 seconds
    const DEFAULT_EXCLUSIVE_DURATION: u64 = 30; // 30 seconds
    const DEFAULT_PRIVATE_CANCELLATION_DURATION: u64 = 60; // 1 minute

    public fun get_safety_deposit_metadata(): Object<Metadata> {
        object::address_to_object(DEFAULT_SAFETY_DEPOSIT_METADATA_ADDRESS)
    }

    public fun get_safety_deposit_amount(): u64 {
        DEFAULT_SAFETY_DEPOSIT_AMOUNT
    }

    public fun get_finality_duration(): u64 {
        DEFAULT_FINALITY_DURATION
    }

    public fun get_exclusive_duration(): u64 {
        DEFAULT_EXCLUSIVE_DURATION
    }

    public fun get_private_cancellation_duration(): u64 {
        DEFAULT_PRIVATE_CANCELLATION_DURATION
    }
}
