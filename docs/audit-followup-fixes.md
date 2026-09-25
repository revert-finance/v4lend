# Verified Scan #1 follow-up fixes

These commits build on PR #40 at `0a8a81a976c5bc7b1a8d047af9fa845140b0b79e`.

## V4LE-57: isolate CI credentials from PR code

PR build/mock tests receive no RPC secret and disable FFI. Archive tests run only on `main`
(push or manual dispatch), in the `archive-rpc` environment, with the credential scoped to the
single test step. Missing credentials fail visibly instead of silently skipping fork coverage.

Before supplying a key, configure `archive-rpc` to permit deployments only from `main`, protect
that branch and add required environment reviewers as appropriate. Store `MAINNET_RPC_URL` only
in that environment: remove repository/inherited organization versions. A repository writer can
edit another workflow to reference repository secrets, so the environment boundary is essential.
Use a dedicated restricted, quota-limited RPC key. Do not use `pull_request_target` plus PR checkout.

V4LE-73 is an operational item: confirm historical key revocation/rotation in the provider's
activity log. No repository edit or history rewrite proves that the old key is invalid.
