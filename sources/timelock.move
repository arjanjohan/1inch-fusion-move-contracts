module fusion_plus::timelock {
    use aptos_framework::timestamp;

    /// Phase constants
    const PHASE_FINALITY: u8 = 0;
    const PHASE_EXCLUSIVE: u8 = 1;
    const PHASE_PRIVATE_CANCELLATION: u8 = 2;
    const PHASE_PUBLIC_CANCELLATION: u8 = 3;

    /// A timelock that enforces time-based phases for asset locking.
    /// The timelock progresses through phases:
    /// 1. Finality - Initial lock period where settings can be modified
    /// 2. Exclusive - Only intended recipient can claim
    /// 3. Private Cancellation - Owner can cancel and reclaim (private)
    /// 4. Public Cancellation - Anyone can cancel and claim (public)
    ///
    /// @param created_at When this timelock was created.
    /// @param finality_duration Duration of finality phase in seconds.
    /// @param exclusive_duration Duration of exclusive phase in seconds.
    /// @param private_cancellation_duration Duration of private cancellation phase in seconds.
    struct Timelock has copy, drop, store {
        created_at: u64,
        finality_duration: u64,
        exclusive_duration: u64,
        private_cancellation_duration: u64
    }

    public fun new(): Timelock {
        let finality_duration = 10;
        let exclusive_duration = 10;
        let private_cancellation_duration = 10;
        new_internal(
            finality_duration, exclusive_duration, private_cancellation_duration
        )
    }

    public fun new_from_durations(
        finality_duration: u64, exclusive_duration: u64, private_cancellation_duration: u64
    ): Timelock {
        new_internal(
            finality_duration, exclusive_duration, private_cancellation_duration
        )
    }

    /// Creates a new Timelock with the specified durations.
    ///
    /// @param finality_duration Duration of finality phase in seconds.
    /// @param exclusive_duration Duration of exclusive phase in seconds.
    /// @param private_cancellation_duration Duration of private cancellation phase in seconds.
    public fun new_internal(
        finality_duration: u64, exclusive_duration: u64, private_cancellation_duration: u64
    ): Timelock {

        Timelock {
            created_at: timestamp::now_seconds(),
            finality_duration,
            exclusive_duration,
            private_cancellation_duration
        }
    }

    /// Gets the current phase of a Timelock based on elapsed time.
    ///
    /// @param timelock The Timelock to check.
    /// @return u8 The current phase (PHASE_FINALITY, PHASE_EXCLUSIVE, PHASE_PRIVATE_CANCELLATION, or PHASE_PUBLIC_CANCELLATION).
    public fun get_phase(timelock: &Timelock): u8 {
        let now = timestamp::now_seconds();
        let finality_end = timelock.created_at + timelock.finality_duration;
        let exclusive_end = finality_end + timelock.exclusive_duration;
        let private_cancellation_end =
            exclusive_end + timelock.private_cancellation_duration;

        if (now < finality_end) {
            PHASE_FINALITY
        } else if (now < exclusive_end) {
            PHASE_EXCLUSIVE
        } else if (now < private_cancellation_end) {
            PHASE_PRIVATE_CANCELLATION
        } else {
            PHASE_PUBLIC_CANCELLATION
        }
    }

    /// Gets the remaining time in the current phase.
    ///
    /// @param timelock The Timelock to check.
    /// @return u64 The remaining time in seconds, or 0 if in public cancellation phase.
    public fun get_remaining_time(timelock: &Timelock): u64 {
        let now = timestamp::now_seconds();
        let finality_end = timelock.created_at + timelock.finality_duration;
        let exclusive_end = finality_end + timelock.exclusive_duration;
        let private_cancellation_end =
            exclusive_end + timelock.private_cancellation_duration;

        if (now < finality_end) {
            finality_end - now
        } else if (now < exclusive_end) {
            exclusive_end - now
        } else if (now < private_cancellation_end) {
            private_cancellation_end - now
        } else { 0 }
    }

    /// Gets the total duration of all phases.
    ///
    /// @param timelock The Timelock to check.
    /// @return u64 The total duration in seconds.
    public fun get_total_duration(timelock: &Timelock): u64 {
        timelock.finality_duration + timelock.exclusive_duration
            + timelock.private_cancellation_duration
    }

    /// Gets the end time of the timelock (when it expires).
    ///
    /// @param timelock The Timelock to check.
    /// @return u64 The expiration timestamp in seconds.
    public fun get_expiration_time(timelock: &Timelock): u64 {
        timelock.created_at + get_total_duration(timelock)
    }

    /// Checks if the timelock is in the finality phase.
    ///
    /// @param timelock The Timelock to check.
    /// @return bool True if in finality phase, false otherwise.
    public fun is_in_finality_phase(timelock: &Timelock): bool {
        get_phase(timelock) == PHASE_FINALITY
    }

    /// Checks if the timelock is in the exclusive phase.
    ///
    /// @param timelock The Timelock to check.
    /// @return bool True if in exclusive phase, false otherwise.
    public fun is_in_exclusive_phase(timelock: &Timelock): bool {
        get_phase(timelock) == PHASE_EXCLUSIVE
    }

    /// Checks if the timelock is in the private cancellation phase.
    ///
    /// @param timelock The Timelock to check.
    /// @return bool True if in private cancellation phase, false otherwise.
    public fun is_in_private_cancellation_phase(timelock: &Timelock): bool {
        get_phase(timelock) == PHASE_PRIVATE_CANCELLATION
    }

    /// Checks if the timelock is in the public cancellation phase.
    ///
    /// @param timelock The Timelock to check.
    /// @return bool True if in public cancellation phase, false otherwise.
    public fun is_in_public_cancellation_phase(timelock: &Timelock): bool {
        get_phase(timelock) == PHASE_PUBLIC_CANCELLATION
    }

    /// Gets the creation timestamp of the timelock.
    ///
    /// @param timelock The Timelock to get timestamp from.
    /// @return u64 The creation timestamp in seconds.
    public fun get_created_at(timelock: &Timelock): u64 {
        timelock.created_at
    }

    /// Gets the finality duration of the timelock.
    ///
    /// @param timelock The Timelock to get finality duration from.
    /// @return u64 The finality duration in seconds.
    public fun get_finality_duration(timelock: &Timelock): u64 {
        timelock.finality_duration
    }

    /// Gets the exclusive duration of the timelock.
    ///
    /// @param timelock The Timelock to get exclusive duration from.
    /// @return u64 The exclusive duration in seconds.
    public fun get_exclusive_duration(timelock: &Timelock): u64 {
        timelock.exclusive_duration
    }

    /// Gets the private cancellation duration of the timelock.
    ///
    /// @param timelock The Timelock to get private cancellation duration from.
    /// @return u64 The private cancellation duration in seconds.
    public fun get_private_cancellation_duration(timelock: &Timelock): u64 {
        timelock.private_cancellation_duration
    }

    /// Gets all durations of the timelock.
    ///
    /// @param timelock The Timelock to get durations from.
    /// @return (u64, u64, u64) The finality, exclusive and cancellation durations in seconds.
    public fun get_durations(timelock: &Timelock): (u64, u64, u64) {
        (
            timelock.finality_duration,
            timelock.exclusive_duration,
            timelock.private_cancellation_duration
        )
    }


    #[test_only]
    public fun get_phase_finality(): u8 {
        PHASE_FINALITY
    }

    #[test_only]
    public fun get_phase_exclusive(): u8 {
        PHASE_EXCLUSIVE
    }

    #[test_only]
    public fun get_phase_private_cancellation(): u8 {
        PHASE_PRIVATE_CANCELLATION
    }

    #[test_only]
    public fun get_phase_public_cancellation(): u8 {
        PHASE_PUBLIC_CANCELLATION
    }

    #[test_only]
    public fun new_for_test(
        finality_duration: u64, exclusive_duration: u64, private_cancellation_duration: u64
    ): Timelock {
        new_internal(
            finality_duration, exclusive_duration, private_cancellation_duration
        )
    }
}
