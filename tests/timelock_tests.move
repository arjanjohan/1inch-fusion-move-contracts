#[test_only]
module fusion_plus::timelock_tests {
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use fusion_plus::timelock;

    // Test durations (short for testing)
    const FINALITY_DURATION: u64 = 60; // 1 minute
    const EXCLUSIVE_WITHDRAWAL_DURATION: u64 = 120; // 2 minutes
    const PUBLIC_WITHDRAWAL_DURATION: u64 = 180; // 3 minutes
    const PRIVATE_CANCELLATION_DURATION: u64 = 180; // 3 minutes

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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Verify initial state
        let (finality, exclusive_withdrawal, public_withdrawal, private_cancellation) =
            timelock::get_durations(&timelock);
        assert!(finality == FINALITY_DURATION, 0);
        assert!(exclusive_withdrawal == EXCLUSIVE_WITHDRAWAL_DURATION, 0);
        assert!(public_withdrawal == PUBLIC_WITHDRAWAL_DURATION, 0);
        assert!(private_cancellation == PRIVATE_CANCELLATION_DURATION, 0);
        assert!(timelock::get_created_at(&timelock) == timestamp::now_seconds(), 0);
        assert!(timelock::is_in_finality_phase(&timelock), 0);
    }

    #[test]
    fun test_phase_transitions() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Check initial phase
        assert!(timelock::is_in_finality_phase(&timelock), 0);
        assert!(!timelock::is_in_exclusive_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_public_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(!timelock::is_in_public_cancellation_phase(&timelock), 0);

        // Move to exclusive withdrawal phase
        timestamp::fast_forward_seconds(FINALITY_DURATION + 1);
        assert!(!timelock::is_in_finality_phase(&timelock), 0);
        assert!(timelock::is_in_exclusive_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_public_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(!timelock::is_in_public_cancellation_phase(&timelock), 0);

        // Move to public withdrawal phase
        timestamp::fast_forward_seconds(PUBLIC_WITHDRAWAL_DURATION);
        assert!(!timelock::is_in_finality_phase(&timelock), 0);
        assert!(!timelock::is_in_exclusive_withdrawal_phase(&timelock), 0);
        assert!(timelock::is_in_public_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(!timelock::is_in_public_cancellation_phase(&timelock), 0);

        // Move to private cancellation phase
        timestamp::fast_forward_seconds(EXCLUSIVE_WITHDRAWAL_DURATION);
        assert!(!timelock::is_in_finality_phase(&timelock), 0);
        assert!(!timelock::is_in_exclusive_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_public_withdrawal_phase(&timelock), 0);
        assert!(timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(!timelock::is_in_public_cancellation_phase(&timelock), 0);

        // Move to public cancellation phase
        timestamp::fast_forward_seconds(PRIVATE_CANCELLATION_DURATION + 1);
        assert!(!timelock::is_in_finality_phase(&timelock), 0);
        assert!(!timelock::is_in_exclusive_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_public_withdrawal_phase(&timelock), 0);
        assert!(!timelock::is_in_private_cancellation_phase(&timelock), 0);
        assert!(timelock::is_in_public_cancellation_phase(&timelock), 0);
    }

    #[test]
    fun test_remaining_time() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
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
            timelock::get_remaining_time(&timelock)
                == EXCLUSIVE_WITHDRAWAL_DURATION - 30,
            0
        );

        // Check remaining time in public withdrawal phase (30 seconds into public withdrawal)
        timestamp::update_global_time_for_test_secs(
            FINALITY_DURATION + EXCLUSIVE_WITHDRAWAL_DURATION + 30
        );
        assert!(
            timelock::get_remaining_time(&timelock) == PUBLIC_WITHDRAWAL_DURATION - 30,
            0
        );

        // Check remaining time in private cancellation phase (30 seconds into private cancellation)
        timestamp::update_global_time_for_test_secs(
            FINALITY_DURATION + EXCLUSIVE_WITHDRAWAL_DURATION
                + PUBLIC_WITHDRAWAL_DURATION + 30
        );
        assert!(
            timelock::get_remaining_time(&timelock)
                == PRIVATE_CANCELLATION_DURATION - 30,
            0
        );

        // Check remaining time in public cancellation phase
        timestamp::update_global_time_for_test_secs(
            FINALITY_DURATION + EXCLUSIVE_WITHDRAWAL_DURATION
                + PUBLIC_WITHDRAWAL_DURATION + PRIVATE_CANCELLATION_DURATION + 1
        );
        assert!(timelock::get_remaining_time(&timelock) == 0, 0);
    }

    #[test]
    fun test_total_duration_and_expiration() {
        setup_test();

        let timelock =
            timelock::new_for_test(
                FINALITY_DURATION,
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        let total_duration =
            FINALITY_DURATION + EXCLUSIVE_WITHDRAWAL_DURATION
                + PUBLIC_WITHDRAWAL_DURATION + PRIVATE_CANCELLATION_DURATION;
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
                EXCLUSIVE_WITHDRAWAL_DURATION,
                PUBLIC_WITHDRAWAL_DURATION,
                PRIVATE_CANCELLATION_DURATION
            );

        // Test phase constants
        assert!(timelock::get_phase(&timelock) == timelock::get_phase_finality(), 0);

        // Move to exclusive phase
        timestamp::fast_forward_seconds(FINALITY_DURATION + 1);
        assert!(
            timelock::get_phase(&timelock)
                == timelock::get_phase_exclusive_withdrawal(),
            0
        );

        // Move to public withdrawal phase
        timestamp::fast_forward_seconds(EXCLUSIVE_WITHDRAWAL_DURATION + 1);
        assert!(
            timelock::get_phase(&timelock) == timelock::get_phase_public_withdrawal(),
            0
        );

        // Move to private cancellation phase
        timestamp::fast_forward_seconds(PUBLIC_WITHDRAWAL_DURATION + 1);
        assert!(
            timelock::get_phase(&timelock)
                == timelock::get_phase_private_cancellation(),
            0
        );

        // Move to public cancellation phase
        timestamp::fast_forward_seconds(PRIVATE_CANCELLATION_DURATION + 1);
        assert!(
            timelock::get_phase(&timelock) == timelock::get_phase_public_cancellation(),
            0
        );
    }
}
