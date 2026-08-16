# Device ID Workflow Log Output Design

[English](2026-08-15-device-id-workflow-log-output-design.md) | [简体中文](2026-08-15-device-id-workflow-log-output-design-zh_CN.md)

## 1. Context

The unified Windows and macOS workflows currently treat the UU Remote device ID as remote-device connection information and replace its value with the generic token `DEVICE_ID_STATE=ready`. That makes the workflows safe to inspect, but it prevents an operator from learning the device ID needed to establish a real UU Remote connection.

This design changes the approved data classification. A UU Remote device ID is an operational identifier that may be printed in workflow logs. Account passwords, the UU Remote custom code, and other connection credentials remain secrets and must not be printed.

## 2. Goals

- Print the complete device ID in every successful Windows and macOS workflow run, independent of `debug_level`.
- Use the same machine-readable launch output on both platforms.
- Include the current device ID again in the production `Wait connections` message so an operator can find it at the point of use.
- Keep custom codes and account passwords masked, step-scoped, and absent from logs, screenshots, and artifacts.
- Reject unsafe device-ID output instead of allowing control characters or multiple lines to alter the workflow log.
- Preserve the existing debug gates, wait-result contract, diagnostics, and platform-specific implementations.

## 3. Non-goals

- Do not make the custom code or an account password visible.
- Do not print raw CLI errors, failed polling output, process arguments, window titles, or other remote-connection data.
- Do not add an encrypted artifact, private notification integration, or separate reporting service.
- Do not make `Wait connections` run for debug levels `1`, `2`, or `3`.
- Do not change `WAIT_RESULT=timeout|shutdown/restart` or the accepted wait range.
- Do not add another device-ID CLI call merely to create a dedicated reporting step.

## 4. Data classification

The shared repository policy becomes:

- Account passwords and `UUREMOTE_CUSTOM_CODE` are secrets.
- The UU Remote device ID is a loggable operational identifier.
- Other remote-device connection information remains non-loggable unless a later approved design classifies it explicitly.
- Diagnostic artifacts remain free of device IDs even though the designated workflow log messages may contain them.

The English and Simplified Chinese copies of `AGENTS.md`, `CLAUDE.md`, the README, and the governing parity documents must express this distinction consistently.

## 5. Public log contract

After the first successful non-empty device-ID observation during the unconditional launch/readiness stage, both platforms print exactly:

```text
DEVICE_ID=<complete device ID>
DEVICE_ID_STATE=ready
```

This launch/readiness output occurs once for every successful run at debug levels `0`, `1`, `2`, and `3`.

The production `Wait connections` step remains gated to `debug_level=0`. Immediately before invoking the shutdown-aware wait, it obtains the current device ID again and prints:

```text
WAIT_CONNECTIONS DEVICE_ID=<complete device ID>
```

The existing terminal result remains a separate exact line:

```text
WAIT_RESULT=timeout
```

or:

```text
WAIT_RESULT=shutdown/restart
```

Therefore a successful debug-level `0` run prints the device ID twice: once at launch/readiness and once at the point where connections are awaited. Successful runs at debug levels `1`, `2`, and `3` print it once at launch/readiness.

## 6. Device-ID validation

Only a successful CLI result with a validated non-empty device ID is eligible for logging. A platform may receive either the device ID as a legacy single printable line or a platform-internal JSON envelope. An envelope must be strict UTF-8 JSON with a root object, `success` equal to the JSON boolean `true`, an object-valued `data` member, and a string-valued `data.deviceId`; duplicate object keys are invalid. The envelope itself is never eligible for logging.

After platform-specific extraction, both paths apply the same device-ID validator. After trimming permitted surrounding spaces, the extracted value must be one printable line. A value containing CR, LF, NUL, another C0 control character, DEL, or a Unicode control/non-printing/separator character is invalid.

The fixed prefixes `DEVICE_ID=` and `WAIT_CONNECTIONS DEVICE_ID=` prevent the value from appearing at the beginning of a GitHub workflow-command line. A validation failure is fail-closed and emits only a generic readiness or device-ID validation error. Failed attempts and raw CLI stderr are never echoed.

The workflows do not apply `::add-mask::` to device IDs because masking would replace the value needed by the operator with `***`.

## 7. Platform integration

### 7.1 Windows

`Get-UURemoteDeviceId` remains the single bounded CLI boundary. A small output helper validates a returned value and emits one of the two approved log messages.

`Start-UURemoteAndWaitDevice` emits the launch/readiness pair immediately after the first valid device ID is observed. The real `wait-connections` route obtains and validates the current device ID, emits the wait message, and then invokes the existing shutdown-aware watcher. The injected watcher self-test remains isolated from the installed CLI and does not print a device ID.

### 7.2 macOS

The macOS `assist id` command may return a pretty-printed JSON envelope rather than the ID alone. The helper parses that envelope internally, requires the approved success/data/deviceId structure, rejects malformed or duplicate-key JSON, and validates only the extracted `deviceId`. A legacy non-JSON single-line response remains accepted through the same final device-ID validator. JSON-looking output that fails envelope validation never falls back to the legacy path.

The `apple.sh launch-and-wait-device` route owns macOS launch and readiness: it launches GameViewer only when absent, validates the first successfully extracted `assist id` value, emits the launch/readiness pair, and keeps the application alive after readiness. The helper uses a 60-second overall deadline and a 500-millisecond poll interval.

The real `wait_connections` route obtains and validates the current `assist id` value, emits the wait message, and then invokes the existing Swift watcher. The watcher self-test remains independent from the installed CLI.

The two platforms may use different validation implementations, but their accepted output and failure behavior are equivalent.

## 8. Secret handling and cleanup

The existing handling for `UUREMOTE_CUSTOM_CODE` and account passwords does not change:

- pass secrets only through step-scoped environment variables;
- mask them before any potentially logged command;
- never place them in command output, screenshots, artifacts, source, tests, or defaults;
- remove them from the environment as soon as practical.

Device-ID variables are still cleared after use to keep data flow narrow and prevent accidental reuse, even though the value is not classified as a secret.

## 9. Testing

Implementation follows test-driven development.

Behavior tests must prove:

- Windows and macOS print `DEVICE_ID=<fixture>` followed by `DEVICE_ID_STATE=ready` on the first successful readiness observation.
- The launch/readiness pair is independent of debug level and occurs exactly once per successful run.
- The production wait route prints `WAIT_CONNECTIONS DEVICE_ID=<fixture>` before the unchanged wait result.
- Debug level `0` contains both approved device-ID messages, while debug levels `1`, `2`, and `3` contain only the launch/readiness message.
- Empty, multiline, and control-character values fail closed without emitting the unsafe value.
- Failed retry output and raw CLI stderr remain absent.
- Custom-code and password fixtures remain absent from stdout, stderr, screenshots, and artifacts.
- Diagnostic artifacts do not acquire device-ID content as a side effect of the log change.
- The shutdown-wait self-tests independently observe cleanup: macOS leaves no temporary build directory or watcher process, and Windows returns to the same-process watcher resource baseline.

Contract tests must confirm equivalent Windows and macOS prefixes, ordering, debug gates, and documentation policies. The final verification includes the full repository test suite, bilingual Markdown counterpart/navigation checks, JSON validation, sensitive-value scans, and `git diff --check`.

## 10. Live acceptance

Live validation covers Windows and macOS at debug levels `0` and `1`, plus the existing Windows diagnostic matrix:

- every successful run contains the launch/readiness device-ID pair;
- debug-level `0` contains the wait message with the current device ID;
- a mobile client can use the printed device ID and the separately configured custom code to connect;
- logs and artifacts contain no custom code or account password;
- artifacts retain their existing names and file contents;
- timeout and shutdown/restart runs retain their exact `WAIT_RESULT` values.

The executable injected shutdown-wait self-test provides deterministic evidence for the exact `WAIT_RESULT=shutdown/restart` result and cleanup contract. It must pass before live acceptance.

Live acceptance is separate: it requires a successful mobile-client connection and observation of the requested real shutdown/offline effect. The user initiates the remote shutdown/restart action; the agent must not issue an operating-system shutdown command.

Post-shutdown/restart GitHub log, result, and cleanup reporting is best-effort and non-blocking. Missing reporting after shutdown/restart begins is not a watcher failure and does not block acceptance when the deterministic self-test passed and the live connection and shutdown/offline effect were observed.
