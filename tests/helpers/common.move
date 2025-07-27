#[test_only]
module fusion_plus::common {
    use std::option::{Self};
    use std::string::utf8;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self};
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;

    public fun initialize_account_with_fa(address: address): signer {
        let signer = account::create_account_for_test(address);
        let fa = aptos_coin::mint_apt_fa_for_test(100_000_000_000_000_000);
        primary_fungible_store::deposit(address, fa);
        signer
    }

    public fun create_test_token(owner: &signer, seed: vector<u8>):
        (Object<Metadata>, MintRef) {
        let constructor_ref = object::create_named_object(owner, seed);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            utf8(seed),
            utf8(b"TEST"),
            8,
            utf8(b""),
            utf8(b"")
        );

        let metadata = object::object_from_constructor_ref(&constructor_ref);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);

        (metadata, mint_ref)
    }

    public fun mint_fa(mint_ref: &MintRef, amount: u64, address: address) {
        let fa = fungible_asset::mint(mint_ref, amount);
        primary_fungible_store::deposit(address, fa);
    }
}
