# UU Remote Secrets and Shutdown-Aware Wait Design

## Goal

Remove the plaintext account-password workflow input and make `Wait connections`
finish early only when macOS begins shutting down or restarting.

The waiting step must not finish early because UU Remote disconnects, the UU
Remote processes exit, the network becomes unavailable, or the graphical user
logs out.

## Scope

This change covers:

- sourcing the shared account password from a GitHub Actions repository secret;
- preserving the existing host-password, login-keychain, and `/etc/kcpassword`
  configuration behavior;
- replacing the fixed wait with a shutdown-aware bounded wait;
- automated contract and macOS behavior tests.

It does not change the UU Remote permission automation, debug-level semantics,
locale selection, or the supported `wait_connections_seconds` range.

## Password Secret

Remove the visible `workflow_dispatch.inputs.account_password` input. The
workflow will instead read this repository Actions secret:

```text
UUREMOTE_ACCOUNT_PASSWORD
```

The `Configure host` step will expose the secret to that step only through an
environment variable with the same name. Before running host configuration, it
will reject a missing or empty value with a clear error. It will not fall back
to `john.doe` or any other default.

GitHub masks secret values automatically. The step will also register the value
with the Actions log masker before invoking `apple.sh`; no command may print the
value.

The secret remains the single value used for:

- the graphical desktop user's account password;
- the root account password, without enabling direct root login;
- the graphical user's login keychain password;
- the root login keychain password;
- `/etc/kcpassword`.

## Wait Contract

The existing `wait_connections_seconds` workflow input remains an integer with
a default of 300 and an inclusive valid range of 0 through 21000 seconds.

`Wait connections` has two successful completion paths:

1. the requested duration elapses; or
2. macOS emits a system-defined power-off event indicating that shutdown or
   restart is in progress.

The value 0 returns immediately and does not start the AppKit watcher.

No UU Remote CLI, process, socket, connection, or network state participates in
the decision. A user logout is never interpreted as a successful early
completion.

## Shutdown Detection

`apple.sh` will expose a dedicated wait command used by `macos.yml`. The command
will compile a small checked-in Swift/AppKit source file to a temporary helper
and run it in the active graphical session. The helper will have no window and
no Dock presence.

The helper will run an AppKit event loop and install both local and global
monitors for `NSEvent.EventType.systemDefined`. It completes only when an event's
subtype is `NSEvent.EventSubtype.powerOff`. Apple defines that subtype as an
event indicating that system shutdown or restart is in progress.

Both monitors are used because a local monitor sees events dispatched to the
helper itself, while a global monitor sees copies of matching events dispatched
to other applications. The first matching event wins; cleanup is idempotent.

`NSWorkspace.willPowerOffNotification` is deliberately not used as a completion
condition because Apple documents it as occurring for logout as well as power
off. Process `SIGTERM`, UU Remote process exit, and connectivity polling are also
not completion conditions because they cannot uniquely identify shutdown or
restart.

The helper will use a monotonic timer for the requested duration. It will print
one short completion reason (`timeout` or `shutdown/restart`) and return success.
Initialization or compilation failures return nonzero so the workflow does not
silently skip the requested wait.

The temporary binary and build directory will be removed on every normal exit
and caught shell termination path.

## Workflow Integration

`macos.yml` retains validation of `wait_connections_seconds`, then invokes the
new `apple.sh` wait command instead of calling one fixed `sleep`.

This step remains after UU Remote launch and permission configuration, with its
existing workflow debug-level gate unchanged. Its completion decision does not
depend on debug level, screenshots, artifacts, idempotency checks, or the
level-3 live diagnostic sampler.

## Failure and Lifecycle Behavior

- Missing or empty password secret: fail before any password mutation.
- Invalid wait value: fail before starting the watcher.
- Swift/AppKit helper cannot compile or initialize: fail the waiting step.
- UU Remote disconnects or exits: keep waiting.
- Network becomes unavailable: keep waiting locally.
- Graphical user logs out: do not report a successful early completion. If the
  logout destroys the graphical session or its GitHub runner, ordinary process
  termination may still interrupt the job; it must not be mislabeled as a
  shutdown/restart match.
- System begins shutdown or restart: print the reason and return from the wait
  immediately.
- Workflow is cancelled or the shell is externally terminated: normal process
  termination applies and temporary files are cleaned when the shell receives a
  trappable signal. Cancellation is not reported as a shutdown event.

After a real shutdown begins, the runner may lose networking before it can send
the final step result to GitHub. The local wait can finish and log its reason,
but the GitHub job may still appear interrupted or disconnected. The workflow
must not claim it can guarantee a final remote status after power loss.

## Testing

Python contract tests will verify that:

- the visible `account_password` input is absent;
- the workflow references only `secrets.UUREMOTE_ACCOUNT_PASSWORD` for this
  password;
- host configuration rejects an empty secret;
- the input default and allowed range remain 300 and 0 through 21000;
- `Wait connections` invokes the `apple.sh` wait command rather than a fixed
  `sleep`;
- the production event predicate requires both `systemDefined` and `powerOff`;
- `NSWorkspace.willPowerOffNotification`, UU process state, and network state do
  not drive completion.

The AppKit helper will provide a test-only event-injection mode exercised on the
macOS runner. Behavioral tests will verify:

- a short duration completes by timeout;
- an injected ordinary system event does not complete the wait;
- an injected `systemDefined`/`powerOff` event completes it early;
- zero seconds returns without starting the helper.

The existing test suite, Bash syntax check, `git diff --check`, and an end-to-end
GitHub Actions run must all pass before completion is reported.

## Rollout

Before running the updated workflow, configure the repository Actions secret
`UUREMOTE_ACCOUNT_PASSWORD`. The first end-to-end run should use a short wait to
verify normal timeout behavior. Actual shutdown/restart handling can then be
confirmed on the disposable macOS runner or target machine, with the understood
GitHub reporting limitation after the host loses power.
