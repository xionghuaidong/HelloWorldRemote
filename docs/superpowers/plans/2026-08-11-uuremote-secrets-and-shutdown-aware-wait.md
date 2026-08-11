# UU Remote Secrets and Shutdown-Aware Wait Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Source the macOS account password exclusively from a GitHub Actions secret and let `Wait connections` finish on timeout or an actual macOS shutdown/restart event.

**Architecture:** `macos.yml` injects the repository secret only into host configuration and delegates waiting to `apple.sh`. The shell validates the duration, compiles a focused Swift/AppKit watcher into a private temporary directory, and runs it in the active GUI session. Only a `systemDefined` event with subtype `powerOff` is an early-success signal.

**Tech Stack:** GitHub Actions YAML, Bash 3.2, Swift/AppKit, Python `unittest`.

## Global Constraints

- The secret name is exactly `UUREMOTE_ACCOUNT_PASSWORD`.
- No plaintext password input, fallback password, or password log output remains.
- The same secret configures the console user, disabled root account, available login keychains, and `/etc/kcpassword`.
- Direct root login remains disabled.
- `wait_connections_seconds` defaults to 300 and accepts integers from 0 through 21000 inclusive.
- Shutdown and restart finish early; logout, UU state, process state, and network state do not count as successful early completion.
- Existing debug-level gating remains unchanged; level 0 receives no diagnostic self-test overhead.
- Work directly on `main`, as the user explicitly requested for this temporary task.

## File Structure

- Modify `.github/workflows/macos.yml`: secret injection, diagnostic watcher self-test, and production wait invocation.
- Modify `.github/workflows/apple.sh`: validation, routing, temporary compilation, GUI execution, and self-test routing.
- Create `.github/workflows/uuremote-shutdown-wait.swift`: focused AppKit watcher and internal test-event injection.
- Modify `tests/test_uuremote_host_bootstrap.py`: secret-scoping and missing-secret contracts.
- Create `tests/test_uuremote_wait.py`: workflow, routing, predicate, validation, and macOS behavior tests.

---

### Task 1: Replace the Visible Password Input with an Actions Secret

**Files:**
- Modify: `tests/test_uuremote_host_bootstrap.py:17-46`
- Modify: `.github/workflows/macos.yml:21-56`

**Interfaces:**
- Consumes: repository secret `UUREMOTE_ACCOUNT_PASSWORD`.
- Produces: a step-scoped environment variable of the same name for `apple.sh configure-host`.

- [ ] **Step 1: Replace the old password-input tests with failing secret tests**

```python
def test_password_is_not_a_workflow_dispatch_input(self):
    workflow = text(WORKFLOW_PATH)
    inputs = workflow[
        workflow.index("    inputs:\n") : workflow.index("\npermissions:\n")
    ]
    self.assertNotIn("account_password:", inputs)
    self.assertNotIn("john.doe", inputs)

def test_password_secret_is_scoped_masked_and_required(self):
    workflow = text(WORKFLOW_PATH)
    job_env = workflow[
        workflow.index("    env:\n") : workflow.index("\n    steps:\n")
    ]
    self.assertNotIn("UUREMOTE_ACCOUNT_PASSWORD", job_env)
    block = step_block(workflow, "Configure macOS host")
    self.assertIn(
        "UUREMOTE_ACCOUNT_PASSWORD: ${{ secrets.UUREMOTE_ACCOUNT_PASSWORD }}",
        block,
    )
    self.assertIn('if [ -z "${UUREMOTE_ACCOUNT_PASSWORD:-}" ]; then', block)
    self.assertIn("::add-mask::${UUREMOTE_ACCOUNT_PASSWORD}", block)
    self.assertIn(".github/workflows/apple.sh configure-host", block)
    self.assertNotIn("GITHUB_EVENT_PATH", block)
    self.assertNotIn("inputs.account_password", block)
```

- [ ] **Step 2: Run the focused tests and verify the old workflow fails**

Run:

```bash
python3 -m unittest tests.test_uuremote_host_bootstrap.WorkflowContractTests -v
```

Expected: failures show that the visible input remains and the secret is absent.

- [ ] **Step 3: Remove the input and inject the secret only into host configuration**

Use this exact step shape:

```yaml
      - name: Configure macOS host
        shell: bash
        env:
          UUREMOTE_ACCOUNT_PASSWORD: ${{ secrets.UUREMOTE_ACCOUNT_PASSWORD }}
        run: |
            if [ -z "${UUREMOTE_ACCOUNT_PASSWORD:-}" ]; then
                echo "Repository secret UUREMOTE_ACCOUNT_PASSWORD is required" >&2
                exit 2
            fi

            echo "::add-mask::${UUREMOTE_ACCOUNT_PASSWORD}"
            .github/workflows/apple.sh configure-host
            unset UUREMOTE_ACCOUNT_PASSWORD
```

Do not put the secret in job-level `env` and do not keep a default password.

- [ ] **Step 4: Run the focused tests and verify they pass**

Run the Step 2 command. Expected: all `WorkflowContractTests` pass.

- [ ] **Step 5: Commit the secret migration**

```bash
git add .github/workflows/macos.yml tests/test_uuremote_host_bootstrap.py
git commit -m "security: source macOS password from Actions secret"
```

### Task 2: Define the Wait Contract and Shell Routing

**Files:**
- Create: `tests/test_uuremote_wait.py`
- Modify: `.github/workflows/apple.sh:4-6,982-990`
- Modify: `.github/workflows/macos.yml:125-142`

**Interfaces:**
- Consumes: `apple.sh wait-connections <seconds>` with an integer in `0...21000`.
- Produces: exit 0 for zero without AppKit, exit 2 for invalid input, and watcher execution for a positive value.

- [ ] **Step 1: Add failing workflow and shell-routing tests**

Create `tests/test_uuremote_wait.py`:

```python
from pathlib import Path
import platform
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/macos.yml"
SCRIPT_PATH = ROOT / ".github/workflows/apple.sh"
WATCHER_PATH = ROOT / ".github/workflows/uuremote-shutdown-wait.swift"

def text(path: Path) -> str:
    return path.read_text(encoding="utf-8")

def step_block(workflow: str, name: str) -> str:
    marker = f"      - name: {name}\n"
    start = workflow.index(marker)
    next_step = workflow.find("\n      - name: ", start + len(marker))
    return workflow[start:] if next_step < 0 else workflow[start:next_step]

class WaitWorkflowContractTests(unittest.TestCase):
    def test_input_range_debug_gate_and_delegation(self):
        workflow = text(WORKFLOW_PATH)
        self.assertIn("default: 300", workflow)
        self.assertIn("0-21000", workflow)
        block = step_block(workflow, "Wait connections")
        self.assertIn("if: success() && env.UUREMOTE_DEBUG == '0'", block)
        self.assertIn(
            '.github/workflows/apple.sh wait-connections "$wait_seconds"',
            block,
        )
        self.assertNotIn('sleep "$wait_seconds"', block)

class WaitShellContractTests(unittest.TestCase):
    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), *args], cwd=ROOT,
            text=True, capture_output=True, check=False,
        )

    def test_zero_returns_without_watcher_or_app_preflight(self):
        result = self.run_script("wait-connections", "0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("disabled (0 seconds)", result.stdout)

    def test_invalid_values_return_two(self):
        for value in ("-1", "21001", "1.5", "text", ""):
            with self.subTest(value=value):
                result = self.run_script("wait-connections", value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("integer in the range 0-21000", result.stderr)

    def test_wait_route_precedes_uuremote_app_preflight(self):
        script = text(SCRIPT_PATH)
        route = 'if [ "$mode" = "wait-connections" ]'
        self.assertLess(
            script.index(route), script.index('if [ ! -d "$APP" ]')
        )
```

- [ ] **Step 2: Run the tests and verify they fail for the missing route**

```bash
python3 -m unittest tests.test_uuremote_wait -v
```

Expected: the workflow, zero, invalid-value, and routing assertions fail.

- [ ] **Step 3: Add validation, zero handling, and preflight routing**

Add:

```bash
validate_wait_connections_seconds() {
    local wait_seconds="${1:-}"
    case "$wait_seconds" in
        ''|*[!0-9]*)
            echo "wait_connections_seconds must be an integer in the range 0-21000; got: $wait_seconds" >&2
            return 2
            ;;
    esac
    if [ "$wait_seconds" -gt 21000 ]; then
        echo "wait_connections_seconds must be an integer in the range 0-21000; got: $wait_seconds" >&2
        return 2
    fi
}

run_shutdown_waiter() {
    echo "Shutdown watcher is not available" >&2
    return 1
}

wait_connections() {
    local wait_seconds="${1:-}"
    validate_wait_connections_seconds "$wait_seconds" || return "$?"
    if [ "$wait_seconds" -eq 0 ]; then
        echo "Wait connections disabled (0 seconds)"
        return 0
    fi
    run_shutdown_waiter "$wait_seconds" none
}
```

Route before application preflight:

```bash
if [ "$mode" = "wait-connections" ]; then
    wait_connections "${2:-}"
    exit $?
fi
```

- [ ] **Step 4: Replace only the fixed workflow sleep with delegation**

```bash
echo "Waiting connections for $wait_seconds seconds ..."
.github/workflows/apple.sh wait-connections "$wait_seconds"
```

- [ ] **Step 5: Run the Task 2 tests and Bash syntax check**

```bash
python3 -m unittest tests.test_uuremote_wait -v
bash -n .github/workflows/apple.sh
```

Expected: all Task 2 tests and syntax checks pass; positive waits still fail explicitly through the temporary stub.

- [ ] **Step 6: Commit the wait contract and routing**

```bash
git add .github/workflows/apple.sh .github/workflows/macos.yml tests/test_uuremote_wait.py
git commit -m "feat: route connection waits through apple script"
```

### Task 3: Implement and Behavior-Test the AppKit Watcher

**Files:**
- Create: `.github/workflows/uuremote-shutdown-wait.swift`
- Modify: `.github/workflows/apple.sh` wait helper functions
- Modify: `tests/test_uuremote_wait.py`

**Interfaces:**
- Consumes: watcher arguments `<seconds> [none|ordinary|power-off]`; production passes `none`.
- Produces: one `WAIT_RESULT=timeout` or `WAIT_RESULT=shutdown/restart` line and exit 0.
- Produces: `apple.sh self-test-wait-connections` for timeout, unrelated-event, and power-off scenarios.

- [ ] **Step 1: Add failing predicate and macOS behavior tests**

Append:

```python
class WaitWatcherSourceTests(unittest.TestCase):
    def test_only_exact_power_off_event_finishes_early(self):
        source = text(WATCHER_PATH)
        self.assertIn("event.type == .systemDefined", source)
        self.assertIn("event.subtype == .powerOff", source)
        self.assertNotIn("willPowerOffNotification", source)
        for forbidden in ("UURemote", "uuyc", "NWPathMonitor", "URLSession"):
            self.assertNotIn(forbidden, source)

@unittest.skipUnless(platform.system() == "Darwin", "requires AppKit")
class WaitWatcherBehaviorTests(unittest.TestCase):
    def test_shell_self_test_passes(self):
        result = subprocess.run(
            ["/bin/bash", str(SCRIPT_PATH), "self-test-wait-connections"],
            cwd=ROOT, text=True, capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("shutdown-aware wait self-test passed", result.stdout)
```

- [ ] **Step 2: Run tests and verify the missing Swift source fails**

Run the Task 2 test command. Expected: the source test errors; AppKit behavior is skipped off macOS.

- [ ] **Step 3: Create the Swift watcher with an exact event predicate**

Implement `ShutdownWaiter` with these core operations:

```swift
import AppKit
import Foundation

enum InjectedEvent: String { case none, ordinary; case powerOff = "power-off" }

final class ShutdownWaiter {
    private let seconds: Int
    private let injectedEvent: InjectedEvent
    private var finished = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    init(seconds: Int, injectedEvent: InjectedEvent) {
        self.seconds = seconds
        self.injectedEvent = injectedEvent
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .systemDefined && event.subtype == .powerOff {
            finish("shutdown/restart")
        }
        return event
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        print("WAIT_RESULT=\(reason)")
        fflush(stdout)
        NSApplication.shared.stop(nil)
        let wake = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0
        )!
        NSApplication.shared.postEvent(wake, atStart: false)
    }

    private func scheduleInjectedEvent(on app: NSApplication) {
        guard injectedEvent != .none else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            [weak self] in
            guard let self else { return }
            let subtype: NSEvent.EventSubtype =
                self.injectedEvent == .powerOff ? .powerOff : .mouseEvent
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, subtype: subtype.rawValue, data1: 0, data2: 0
            )!
            app.postEvent(event, atStart: false)
        }
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in self?.handle(event) ?? event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) {
            [weak self] event in _ = self?.handle(event)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            [weak self] in self?.finish("timeout")
        }
        scheduleInjectedEvent(on: app)
        app.run()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 || arguments.count == 2,
      let seconds = Int(arguments[0]),
      (0...21000).contains(seconds)
else {
    fputs("usage: uuremote-shutdown-wait <0-21000> [none|ordinary|power-off]\n", stderr)
    exit(2)
}
let eventText = arguments.count == 2 ? arguments[1] : "none"
guard let injectedEvent = InjectedEvent(rawValue: eventText) else {
    fputs("invalid injected event: \(eventText)\n", stderr)
    exit(2)
}
ShutdownWaiter(seconds: seconds, injectedEvent: injectedEvent).run()
```

The injected-event argument is reachable only through the shell self-test;
production `wait-connections` always passes `none`.

- [ ] **Step 4: Replace the shell stub with private compilation and GUI execution**

Implement a subshell function so cleanup always runs:

```bash
run_shutdown_waiter() (
    set -euo pipefail
    wait_seconds="$1"
    injected_event="${2:-none}"
    script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    watcher_source="$script_dir/uuremote-shutdown-wait.swift"
    build_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/uuremote-shutdown-wait.XXXXXX")"
    watcher_binary="$build_dir/uuremote-shutdown-wait"
    /bin/chmod 0700 "$build_dir"
    cleanup_shutdown_waiter() {
        /bin/rm -f -- "$watcher_binary"
        /bin/rmdir "$build_dir" 2>/dev/null || true
    }
    trap cleanup_shutdown_waiter EXIT HUP INT TERM
    /usr/bin/xcrun swiftc -framework AppKit "$watcher_source" -o "$watcher_binary"
    resolve_console_account
    run_as_console_user "$watcher_binary" "$wait_seconds" "$injected_event"
)
```

- [ ] **Step 5: Add the shell self-test route**

Add:

```bash
self_test_wait_connections() {
    local result

    result="$(run_shutdown_waiter 1 none)"
    if [ "$result" != "WAIT_RESULT=timeout" ]; then
        echo "Timeout wait self-test failed: $result" >&2
        return 1
    fi

    result="$(run_shutdown_waiter 1 ordinary)"
    if [ "$result" != "WAIT_RESULT=timeout" ]; then
        echo "Ordinary-event wait self-test failed: $result" >&2
        return 1
    fi

    result="$(run_shutdown_waiter 2 power-off)"
    if [ "$result" != "WAIT_RESULT=shutdown/restart" ]; then
        echo "Power-off wait self-test failed: $result" >&2
        return 1
    fi

    echo "shutdown-aware wait self-test passed"
}
```

Route `self-test-wait-connections` before UU application/debug preflight beside
`self-test-kcpassword`.

- [ ] **Step 6: Run static tests and Bash syntax off macOS**

```bash
python3 -m unittest tests.test_uuremote_wait -v
bash -n .github/workflows/apple.sh
```

Expected: source/routing tests pass, the AppKit test is skipped off macOS, and Bash syntax passes.

- [ ] **Step 7: Commit the watcher implementation**

```bash
git add .github/workflows/apple.sh .github/workflows/uuremote-shutdown-wait.swift tests/test_uuremote_wait.py
git commit -m "feat: stop connection wait on macOS power off"
```

### Task 4: Add Diagnostic macOS Coverage and Verify End to End

**Files:**
- Modify: `.github/workflows/macos.yml` after Checkout
- Modify: `tests/test_uuremote_wait.py`

**Interfaces:**
- Consumes: `UUREMOTE_DEBUG` and `self-test-wait-connections`.
- Produces: AppKit behavior coverage at debug levels 1-3 with no level-0 overhead.

- [ ] **Step 1: Add a failing diagnostic-step contract**

```python
def test_appkit_self_test_is_diagnostic_only(self):
    workflow = text(WORKFLOW_PATH)
    block = step_block(workflow, "Test shutdown-aware wait")
    self.assertIn("if: env.UUREMOTE_DEBUG != '0'", block)
    self.assertIn(".github/workflows/apple.sh self-test-wait-connections", block)
```

- [ ] **Step 2: Run the focused test and verify the step is absent**

```bash
python3 -m unittest tests.test_uuremote_wait.WaitWorkflowContractTests.test_appkit_self_test_is_diagnostic_only -v
```

Expected: error locating the missing step.

- [ ] **Step 3: Add the diagnostic-only workflow step immediately after Checkout**

```yaml
      - name: Test shutdown-aware wait
        if: env.UUREMOTE_DEBUG != '0'
        shell: bash
        run: |
            .github/workflows/apple.sh self-test-wait-connections
```

- [ ] **Step 4: Run the full local verification set**

```bash
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
```

Expected: all non-AppKit tests pass, the Darwin behavior test is skipped off macOS, and syntax/whitespace checks pass.

- [ ] **Step 5: Configure the repository Actions secret without logging it**

Create or update `UUREMOTE_ACCOUNT_PASSWORD` in GitHub repository Actions
secrets using the temporary password already approved by the owner. Do not put
its value in a command line, commit, workflow input, screenshot, or response.

- [ ] **Step 6: Commit and push diagnostic coverage**

```bash
git add .github/workflows/macos.yml tests/test_uuremote_wait.py
git commit -m "test: exercise shutdown watcher on diagnostic runs"
git push origin main
```

- [ ] **Step 7: Dispatch a diagnostic workflow run**

Run `macOS` with `debug_level=1` and `wait_connections_seconds=0`. Expected in
`Test shutdown-aware wait`:

```text
WAIT_RESULT=timeout
WAIT_RESULT=timeout
WAIT_RESULT=shutdown/restart
shutdown-aware wait self-test passed
```

The full workflow must succeed and the password must appear only as `***`, if represented at all.

- [ ] **Step 8: Dispatch the default fast workflow run**

Run `macOS` with `debug_level=0` and `wait_connections_seconds=5`. Expected:

- watcher self-test skipped;
- UU installation and permission configuration succeed;
- `Wait connections` prints `WAIT_RESULT=timeout` after about five seconds;
- no screenshot artifact is uploaded.

- [ ] **Step 9: Perform final repository verification**

```bash
python3 -m unittest discover -s tests -v
bash -n .github/workflows/apple.sh
git diff --check
git status --short --branch
git rev-parse HEAD
git rev-parse origin/main
```

Expected: tests and syntax pass, the tree is clean at `main...origin/main`, and both hashes match.
