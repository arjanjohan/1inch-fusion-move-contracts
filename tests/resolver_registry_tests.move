#[test_only]
module fusion_plus::resolver_registry_tests {
    use std::signer;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use fusion_plus::resolver_registry::{Self};

    fun setup_test(): (signer, signer, signer) {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
        let admin = account::create_account_for_test(@fusion_plus);

        timestamp::update_global_time_for_test_secs(1999);
        resolver_registry::init_module_for_test();

        let resolver1 = account::create_account_for_test(@0x201);
        let resolver2 = account::create_account_for_test(@0x202);

        (admin, resolver1, resolver2)
    }

    #[test]
    fun test_register_resolver_happy_flow() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);

        // Verify resolver is active
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        // Verify registration timestamp
        let registered_at = resolver_registry::get_resolver_registered_at(resolver_address);
        assert!(registered_at > 0, 0);

        // Verify last status change timestamp
        let last_status_change = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(last_status_change > 0, 0);
        assert!(last_status_change == registered_at, 0); // Should be same initially
    }

    #[test]
    fun test_register_multiple_resolvers() {
        let (admin, resolver1, resolver2) = setup_test();

        let resolver1_address = signer::address_of(&resolver1);
        let resolver2_address = signer::address_of(&resolver2);

        // Register first resolver
        resolver_registry::register_resolver(&admin, resolver1_address);
        assert!(resolver_registry::is_active_resolver(resolver1_address), 0);

        // Register second resolver
        resolver_registry::register_resolver(&admin, resolver2_address);
        assert!(resolver_registry::is_active_resolver(resolver2_address), 0);

        // Verify both are active
        assert!(resolver_registry::is_active_resolver(resolver1_address), 0);
        assert!(resolver_registry::is_active_resolver(resolver2_address), 0);
    }

    #[test]
    #[expected_failure(abort_code = resolver_registry::EALREADY_REGISTERED)]
    fun test_register_resolver_already_registered() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver first time
        resolver_registry::register_resolver(&admin, resolver_address);

        // Try to register same resolver again
        resolver_registry::register_resolver(&admin, resolver_address);
    }

    #[test]
    fun test_deactivate_resolver_happy_flow() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        // Fast forward time before deactivation
        timestamp::fast_forward_seconds(100);

        // Deactivate resolver
        resolver_registry::deactivate_resolver(&admin, resolver_address);

        // Verify resolver is inactive
        assert!(resolver_registry::is_active_resolver(resolver_address) == false, 0);

        // Verify last status change timestamp updated
        let last_status_change = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(last_status_change > resolver_registry::get_resolver_registered_at(resolver_address), 0);
    }

    #[test]
    #[expected_failure(abort_code = resolver_registry::ENOT_AUTHORIZED)]
    fun test_deactivate_resolver_unauthorized() {
        let (admin, resolver, unauthorized) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);

        // Try to deactivate with unauthorized account
        resolver_registry::deactivate_resolver(&unauthorized, resolver_address);
    }

    #[test]
    #[expected_failure(abort_code = resolver_registry::ENOT_REGISTERED)]
    fun test_deactivate_resolver_not_registered() {
        let (admin, _, _) = setup_test();

        let unregistered_address = @0x999;

        // Try to deactivate unregistered resolver
        resolver_registry::deactivate_resolver(&admin, unregistered_address);
    }

    #[test]
    #[expected_failure(abort_code = resolver_registry::EINVALID_STATUS_CHANGE)]
    fun test_deactivate_resolver_already_inactive() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);

        // Deactivate resolver
        resolver_registry::deactivate_resolver(&admin, resolver_address);

        // Try to deactivate again
        resolver_registry::deactivate_resolver(&admin, resolver_address);
    }

    #[test]
    fun test_reactivate_resolver_happy_flow() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        // Fast forward time before deactivation
        timestamp::fast_forward_seconds(100);

        // Deactivate resolver
        resolver_registry::deactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address) == false, 0);

        // Fast forward time before reactivation
        timestamp::fast_forward_seconds(100);

        // Reactivate resolver
        resolver_registry::reactivate_resolver(&admin, resolver_address);

        // Verify resolver is active again
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        // Verify last status change timestamp updated
        let last_status_change = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(last_status_change > resolver_registry::get_resolver_registered_at(resolver_address), 0);
    }

    #[test]
    #[expected_failure(abort_code = resolver_registry::ENOT_AUTHORIZED)]
    fun test_reactivate_resolver_unauthorized() {
        let (admin, resolver, unauthorized) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);

        // Deactivate resolver
        resolver_registry::deactivate_resolver(&admin, resolver_address);

        // Try to reactivate with unauthorized account
        resolver_registry::reactivate_resolver(&unauthorized, resolver_address);
    }

    #[test]
    #[expected_failure(abort_code = resolver_registry::ENOT_REGISTERED)]
    fun test_reactivate_resolver_not_registered() {
        let (admin, _, _) = setup_test();

        let unregistered_address = @0x999;

        // Try to reactivate unregistered resolver
        resolver_registry::reactivate_resolver(&admin, unregistered_address);
    }

    #[test]
    #[expected_failure(abort_code = resolver_registry::EINVALID_STATUS_CHANGE)]
    fun test_reactivate_resolver_already_active() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver (already active)
        resolver_registry::register_resolver(&admin, resolver_address);

        // Try to reactivate already active resolver
        resolver_registry::reactivate_resolver(&admin, resolver_address);
    }

    #[test]
    fun test_is_active_resolver_edge_cases() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);
        let unregistered_address = @0x999;

        // Test unregistered address
        assert!(resolver_registry::is_active_resolver(unregistered_address) == false, 0);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        // Deactivate resolver
        resolver_registry::deactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address) == false, 0);

        // Reactivate resolver
        resolver_registry::reactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);
    }

    #[test]
    fun test_resolver_timestamps() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Record time before registration
        let before_registration = timestamp::now_seconds();

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);

        let registered_at = resolver_registry::get_resolver_registered_at(resolver_address);
        let initial_status_change = resolver_registry::get_resolver_last_status_change(resolver_address);

        // Verify timestamps are reasonable
        assert!(registered_at >= before_registration, 0);
        assert!(initial_status_change == registered_at, 0);

        // Fast forward time and deactivate
        timestamp::fast_forward_seconds(100);

        resolver_registry::deactivate_resolver(&admin, resolver_address);

        let after_deactivation = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(after_deactivation > initial_status_change, 0);

        // Fast forward time and reactivate
        timestamp::fast_forward_seconds(100);

        resolver_registry::reactivate_resolver(&admin, resolver_address);

        let after_reactivation = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(after_reactivation > after_deactivation, 0);
    }

    #[test]
    fun test_multiple_status_changes() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        let initial_status_change = resolver_registry::get_resolver_last_status_change(resolver_address);

        // Fast forward time and deactivate
        timestamp::fast_forward_seconds(50);
        resolver_registry::deactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address) == false, 0);

        let after_deactivation = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(after_deactivation > initial_status_change, 0);

        // Fast forward time and reactivate
        timestamp::fast_forward_seconds(50);
        resolver_registry::reactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        let after_reactivation = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(after_reactivation > after_deactivation, 0);

        // Fast forward time and deactivate again
        timestamp::fast_forward_seconds(50);
        resolver_registry::deactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address) == false, 0);

        let final_status_change = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(final_status_change > after_reactivation, 0);
    }

    #[test]
    fun test_resolver_lifecycle_complete() {
        let (admin, resolver, _) = setup_test();

        let resolver_address = signer::address_of(&resolver);

        // 1. Register resolver
        resolver_registry::register_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        let registered_at = resolver_registry::get_resolver_registered_at(resolver_address);
        assert!(registered_at > 0, 0);

        // 2. Fast forward time and deactivate resolver
        timestamp::fast_forward_seconds(100);
        resolver_registry::deactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address) == false, 0);

        let deactivated_at = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(deactivated_at > registered_at, 0);

        // 3. Fast forward time and reactivate resolver
        timestamp::fast_forward_seconds(100);
        resolver_registry::reactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address), 0);

        let reactivated_at = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(reactivated_at > deactivated_at, 0);

        // 4. Fast forward time and final deactivation
        timestamp::fast_forward_seconds(100);
        resolver_registry::deactivate_resolver(&admin, resolver_address);
        assert!(resolver_registry::is_active_resolver(resolver_address) == false, 0);

        let final_deactivation = resolver_registry::get_resolver_last_status_change(resolver_address);
        assert!(final_deactivation > reactivated_at, 0);
    }

    #[test]
    fun test_multiple_resolvers_independent_lifecycle() {
        let (admin, resolver1, resolver2) = setup_test();

        let resolver1_address = signer::address_of(&resolver1);
        let resolver2_address = signer::address_of(&resolver2);

        // Register both resolvers
        resolver_registry::register_resolver(&admin, resolver1_address);
        resolver_registry::register_resolver(&admin, resolver2_address);

        assert!(resolver_registry::is_active_resolver(resolver1_address), 0);
        assert!(resolver_registry::is_active_resolver(resolver2_address), 0);

        // Deactivate only resolver1
        resolver_registry::deactivate_resolver(&admin, resolver1_address);

        assert!(resolver_registry::is_active_resolver(resolver1_address) == false, 0);
        assert!(resolver_registry::is_active_resolver(resolver2_address), 0); // Still active

        // Reactivate resolver1
        resolver_registry::reactivate_resolver(&admin, resolver1_address);

        assert!(resolver_registry::is_active_resolver(resolver1_address), 0);
        assert!(resolver_registry::is_active_resolver(resolver2_address), 0); // Still active

        // Deactivate resolver2
        resolver_registry::deactivate_resolver(&admin, resolver2_address);

        assert!(resolver_registry::is_active_resolver(resolver1_address), 0); // Still active
        assert!(resolver_registry::is_active_resolver(resolver2_address) == false, 0);
    }
}