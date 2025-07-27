#[test_only]
module fusion_plus::hashlock_tests {
    use std::vector;
    use std::hash;
    use fusion_plus::hashlock;

    // Test constants
    const TEST_SECRET: vector<u8> = b"my secret";
    const WRONG_SECRET: vector<u8> = b"wrong secret";
    const INVALID_HASH: vector<u8> = b"too short";

    #[test]
    fun test_create_hashlock() {
        let test_hash = hash::sha3_256(TEST_SECRET);
        let hashlock = hashlock::create_hashlock(test_hash);
        assert!(hashlock::get_hash(&hashlock) == test_hash, 0);
    }

    #[test]
    fun test_verify_hashlock() {
        let hashlock = hashlock::create_hashlock_for_test(TEST_SECRET);
        assert!(hashlock::verify_hashlock(&hashlock, TEST_SECRET), 0);
        assert!(!hashlock::verify_hashlock(&hashlock, WRONG_SECRET), 0);
    }

    #[test]
    #[expected_failure(abort_code = hashlock::EINVALID_HASH)]
    fun test_create_hashlock_invalid_hash() {
        // Try to create hashlock with invalid hash length
        hashlock::create_hashlock(INVALID_HASH);
    }

    #[test]
    #[expected_failure(abort_code = hashlock::EINVALID_SECRET)]
    fun test_verify_hashlock_empty_secret() {
        let hashlock = hashlock::create_hashlock_for_test(TEST_SECRET);
        hashlock::verify_hashlock(&hashlock, vector::empty());
    }
}
