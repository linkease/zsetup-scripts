# Apps migration M8 ordinary applications

Date: 2026-11-22 UTC. No public server was changed.

FastPVE, LinkSpace, ks-cli and KSpeeder were migrated after the FastNet pilot.
Their versioned payloads remain byte-identical to the canonical installers;
standard entries and compatibility aliases are generated outside the payloads.

The ordinary-app subset contains FastNet plus these four applications and
exactly 55 Linux selector records. Existing HTTPS, checksum, cache, argument,
failure and cleanup regression suites passed with the published zsetup binary.
