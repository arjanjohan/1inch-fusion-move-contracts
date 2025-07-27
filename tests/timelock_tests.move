#[test_only]
module fusion_plus::timelock_tests {
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use fusion_plus::timelock;

    // Test durations (short for testing)
    const FINALITY_DURATION: u64 = 60; // 1 minute
    const EXCLUSIVE_DURATION: u64 = 120; // 2 minutes
    const CANCELLATION_DURATION: u64 = 180; // 3 minutes

    fun setup_test() {
        timestamp::set_time_has_started_for_testing(
            &account::create_signer_for_test(@aptos_framework)
        );
    }

    #[test]
    fun test_create_timelock() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                CANCELLATION_DURATION
            );

        // Verify initial state
        let (finality, exclusive, cancellation) = timelock::get_durations(&timelock);
        assert!(finality == FINALITY_DURATION, 0);
        assert!(exclusive == EXCLUSIVE_DURATION, 0);
        assert!(cancellation == CANCELLATION_DURATION, 0);
        assert!(timelock::get_created_at(&timelock) == timestamp::now_seconds(), 0);
        assert!(timelock::is_in_finality_phase(&timelock), 0);
    }

    #[test]
    fun test_phase_transitions() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                CANCELLATION_DURATION
            );

        // Check initial phase
        assert!(timelock::is_in_finality_phase(&timelock), 0);
        assert!(!timelock::is_in_exclusive_phase(&timelock), 0);
        assert!(!timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(!timelock::is_in_public_cancellation_phase(&timelock), 0);

        // Move to exclusive phase
        timestamp::fast_forward_seconds(FINALITY_DURATION + 1);
        assert!(!timelock::is_in_finality_phase(&timelock), 0);
        assert!(timelock::is_in_exclusive_phase(&timelock), 0);
        assert!(!timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(!timelock::is_in_public_cancellation_phase(&timelock), 0);

        // Move to private cancellation phase
        timestamp::fast_forward_seconds(EXCLUSIVE_DURATION + 1);
        assert!(!timelock::is_in_finality_phase(&timelock), 0);
        assert!(!timelock::is_in_exclusive_phase(&timelock), 0);
        assert!(timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(!timelock::is_in_public_cancellation_phase(&timelock), 0);

        // Move to public cancellation phase
        timestamp::fast_forward_seconds(CANCELLATION_DURATION + 1);
        assert!(!timelock::is_in_finality_phase(&timelock), 0);
        assert!(!timelock::is_in_exclusive_phase(&timelock), 0);
        assert!(!timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(timelock::is_in_public_cancellation_phase(&timelock), 0);
    }

    #[test]
    fun test_remaining_time() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                CANCELLATION_DURATION
            );

        // Check remaining time in finality phase (30 seconds in)
        timestamp::update_global_time_for_test_secs(30);
        assert!(
            timelock::get_remaining_time(&timelock) == FINALITY_DURATION - 30,
            0
        );

        // Check remaining time in exclusive phase (30 seconds into exclusive)
        timestamp::update_global_time_for_test_secs(FINALITY_DURATION + 30);
        assert!(
            timelock::get_remaining_time(&timelock) == EXCLUSIVE_DURATION - 30,
            0
        );

        // Check remaining time in private cancellation phase (30 seconds into cancellation)
        timestamp::update_global_time_for_test_secs(
            FINALITY_DURATION + EXCLUSIVE_DURATION + 30
        );
        assert!(
            timelock::get_remaining_time(&timelock) == CANCELLATION_DURATION - 30,
            0
        );

        // Check remaining time in public cancellation phase
        timestamp::update_global_time_for_test_secs(
            FINALITY_DURATION + EXCLUSIVE_DURATION + CANCELLATION_DURATION + 1
        );
        assert!(timelock::get_remaining_time(&timelock) == 0, 0);
    }

    #[test]
    fun test_total_duration_and_expiration() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                CANCELLATION_DURATION
            );

        let total_duration = FINALITY_DURATION + EXCLUSIVE_DURATION
            + CANCELLATION_DURATION;
        assert!(timelock::get_total_duration(&timelock) == total_duration, 0);

        let created_at = timelock::get_created_at(&timelock);
        assert!(
            timelock::get_expiration_time(&timelock) == created_at + total_duration,
            0
        );
    }

    #[test]
    fun test_phase_constants() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_DURATION,
                CANCELLATION_DURATION
            );

        // Test phase constants
        assert!(timelock::get_phase(&timelock) == timelock::get_phase_finality(), 0);

        // Move to exclusive phase
        timestamp::fast_forward_seconds(FINALITY_DURATION + 1);
        assert!(timelock::get_phase(&timelock) == timelock::get_phase_exclusive(), 0);

        // Move to private cancellation phase
        timestamp::fast_forward_seconds(EXCLUSIVE_DURATION + 1);
        assert!(
            timelock::get_phase(&timelock)
                == timelock::get_phase_private_cancellation(),
            0
        );

        // Move to public cancellation phase
        timestamp::fast_forward_seconds(CANCELLATION_DURATION + 1);
        assert!(
            timelock::get_phase(&timelock) == timelock::get_phase_public_cancellation(),
            0
        );
    }

    #[test]
    fun test_duration_validation_functions() {
        setup_test();

        // Test valid durations
        assert!(timelock::is_finality_duration_valid(FINALITY_DURATION), 0);
        assert!(timelock::is_exclusive_duration_valid(EXCLUSIVE_DURATION), 0);
        assert!(
            timelock::is_private_cancellation_duration_valid(CANCELLATION_DURATION),
            0
        );

        // Test invalid durations (too short)
        assert!(!timelock::is_finality_duration_valid(0), 0);
        assert!(!timelock::is_exclusive_duration_valid(10), 0);
        assert!(!timelock::is_private_cancellation_duration_valid(30), 0);

        // Test invalid durations (too long)
        assert!(!timelock::is_finality_duration_valid(40000000), 0);
        assert!(!timelock::is_exclusive_duration_valid(40000000), 0);
        assert!(!timelock::is_private_cancellation_duration_valid(40000000), 0);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_zero_finality() {
        setup_test();
        timelock::new_for_test(0, EXCLUSIVE_DURATION, CANCELLATION_DURATION);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_zero_exclusive() {
        setup_test();
        timelock::new_for_test(FINALITY_DURATION, 0, CANCELLATION_DURATION);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_zero_cancellation() {
        setup_test();
        timelock::new_for_test(FINALITY_DURATION, EXCLUSIVE_DURATION, 0);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_too_short_finality() {
        setup_test();
        timelock::new_for_test(0, EXCLUSIVE_DURATION, CANCELLATION_DURATION);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_too_long_finality() {
        setup_test();
        timelock::new_for_test(40000000, EXCLUSIVE_DURATION, CANCELLATION_DURATION);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_too_short_exclusive() {
        setup_test();
        timelock::new_for_test(FINALITY_DURATION, 10, CANCELLATION_DURATION);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_too_long_exclusive() {
        setup_test();
        timelock::new_for_test(FINALITY_DURATION, 40000000, CANCELLATION_DURATION);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_too_short_cancellation() {
        setup_test();
        timelock::new_for_test(FINALITY_DURATION, EXCLUSIVE_DURATION, 30);
    }

    #[test]
    #[expected_failure(abort_code = timelock::EINVALID_DURATION)]
    fun test_create_timelock_too_long_cancellation() {
        setup_test();
        timelock::new_for_test(FINALITY_DURATION, EXCLUSIVE_DURATION, 40000000);
    }
}
