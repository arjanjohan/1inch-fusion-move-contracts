module fusion_plus::hashlock {
    use std::hash;
    use std::vector;

    // - - - - ERROR CODES - - - -

    /// Invalid secret.
    const EINVALID_SECRET: u64 = 0;
    /// Invalid hash.
    const EINVALID_HASH: u64 = 1;

    // - - - - CONSTANTS - - - -

    /// Expected length of hash in bytes
    const HASH_LENGTH: u64 = 32;
    /// Minimum length of secret in bytes
    const MIN_SECRET_LENGTH: u64 = 1;

    // - - - - STRUCTS - - - -

    /// A hash-based lock that can be unlocked with a secret.
    ///
    /// @param hash The 32-byte hash of the secret that can unlock this lock.
    struct HashLock has copy, drop, store {
        hash: vector<u8>
    }

    // - - - - PUBLIC FUNCTIONS - - - -

    /// Creates a HashLock from a hash value.
    ///
    /// @param hash The 32-byte hash value to use for the lock.
    ///
    /// @reverts EINVALID_HASH if the hash length is not 32 bytes.
    public fun create_hashlock(hash: vector<u8>): HashLock {
        assert!(is_valid_hash(&hash), EINVALID_HASH);
        HashLock { hash }
    }

    /// Verifies a secret against a HashLock.
    ///
    /// @param hashlock The HashLock to verify against.
    /// @param secret The secret to verify.
    /// @param verifier The address attempting verification.
    ///
    /// @reverts EINVALID_SECRET if the secret is empty.
    /// @return bool True if the secret matches the hashlock, false otherwise.
    public fun verify_hashlock(hashlock: &HashLock, secret: vector<u8>): bool {
        assert!(is_valid_secret(&secret), EINVALID_SECRET);
        hashlock.hash == hash::sha3_256(secret)
    }

    /// Gets the hash value from a HashLock.
    ///
    /// @param hashlock The HashLock to get the hash from.
    /// @return vector<u8> The 32-byte hash value.
    public fun get_hash(hashlock: &HashLock): vector<u8> {
        hashlock.hash
    }

    /// Checks if a hash value is valid (32 bytes).
    ///
    /// @param hash The hash value to check.
    /// @return bool True if the hash is valid, false otherwise.
    public fun is_valid_hash(hash: &vector<u8>): bool {
        vector::length(hash) == HASH_LENGTH
    }

    /// Checks if a secret is valid (non-empty).
    ///
    /// @param secret The secret to check.
    /// @return bool True if the secret is valid, false otherwise.
    public fun is_valid_secret(secret: &vector<u8>): bool {
        vector::length(secret) >= MIN_SECRET_LENGTH
    }

    #[test_only]
    /// Creates a HashLock from a secret - test only as it would expose the secret in tx payload.
    ///
    /// @param secret The secret to create a hashlock from.
    /// @return HashLock The created hashlock.
    ///
    /// @reverts EINVALID_SECRET if the secret is empty.
    public fun create_hashlock_for_test(secret: vector<u8>): HashLock {
        assert!(is_valid_secret(&secret), EINVALID_SECRET);
        HashLock { hash: create_hash_for_test(secret) }
    }

    #[test_only]
    public fun create_hash_for_test(secret: vector<u8>): vector<u8> {
        hash::sha3_256(secret)
    }

    #[test]
    fun test_verify_hashlock() {
        let secret = b"test_secret";
        let hashlock = create_hashlock_for_test(secret);
        assert!(verify_hashlock(&hashlock, secret), 0);
    }

    #[test]
    fun test_verify_hashlock_fail() {
        let secret = b"test_secret";
        let wrong_secret = b"wrong_secret";
        let hashlock = create_hashlock_for_test(secret);
        assert!(!verify_hashlock(&hashlock, wrong_secret), 0);
    }
}
