# Docker branch status

This branch is the standalone Docker/Node.js edition. It is intentionally
separate from the native router implementation on `main` and does not build or
publish an OpenWrt IPK.

Backup, profile storage, target inspection, and validation are available for
evaluation. Restore is experimental until this edition implements and tests
mandatory pre-restore snapshots, rollback verification, archive integrity,
identity protections, and safe remote activation equivalent to the native
router engine.
