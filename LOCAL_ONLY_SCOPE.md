# Scope update — no remote storage

Latest direct user instruction: **“do not implement the S3 remote storage.”**

This supersedes every earlier S3/remote-storage item in BUILD_BRIEF.md. Implement and deliver LOCAL-ONLY persistence. Do not implement S3, cloud provider lists, AWS signing, remote upload/retry, credential configuration, Keychain credentials for remote, or remote UI controls. Remove any such code already generated, remote fields and bookkeeping if unused, and related tests/dependencies. CLI should not advertise remote commands (an explicit unsupported explanation is optional, not an implementation). Feature matrix marks remote storage intentionally excluded by user, not an incomplete feature. No network access from the running app is required. All other app/core/filesystem/safety/CLI/physical-memory/callback requirements remain active. Continue to a built/tested working application, not a partial scaffold.
