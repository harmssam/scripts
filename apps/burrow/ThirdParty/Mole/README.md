# Mole engine provenance

Burrow can bundle an unmodified Mole 1.53.0 command-line engine. Mole is a
separate process and is maintained at <https://github.com/tw93/Mole>.

The exact release tag, source revision, source-archive digest, release checksum
digest, and per-architecture binary archive digests live in `VERSION.env`.
`scripts/fetch-mole-engine.sh` verifies all of them before creating a staging
directory. It does not execute downloaded code. The complete corresponding
source archive is retained beside the staged engine and is copied into release
bundles.

Verification re-extracts that repository-pinned archive and compares every
upstream source file's digest and mode with the staged engine. It does not trust
the mutable, co-located `ENGINE_SHA256SUMS` file as the source-tree trust anchor.
It also authenticates the bundled upstream `SHA256SUMS` file against its pinned
digest and checks that its architecture archive entry matches Burrow's pin.

Mole is licensed under GNU GPL version 3. Its unmodified `LICENSE`, README,
security documentation, and source are included in the corresponding-source
archive. Burrow does not use Mole's name, logo, or artwork as its own branding.

To inspect or rebuild the staged dependency:

```bash
./scripts/fetch-mole-engine.sh
./scripts/verify-mole-engine.sh .artifacts/mole/V1.53.0/$(uname -m)
```

The release helpers supplied by upstream can also be rebuilt from the retained
source with Go:

```bash
go build ./cmd/analyze
go build ./cmd/status
```

The downloaded helpers are official release artifacts, not locally produced Go
binaries. This distinction is recorded in the generated `PROVENANCE.txt`.
