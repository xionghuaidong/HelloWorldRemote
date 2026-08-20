# macOS Assist 诊断原子快照实施计划

[English](2026-08-20-macos-assist-diagnostic-atomic-snapshot.md) | [简体中文](2026-08-20-macos-assist-diagnostic-atomic-snapshot-zh_CN.md)

> **面向 agentic worker：** 必须使用子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实施本计划。所有 step 使用 checkbox（`- [ ]`）语法跟踪。

**目标：** 通过 supervisor-owned 原子快照交付现有安全的 19 字段 macOS 无人值守权限诊断，不再依赖窗口末尾的 worker 报告时间。

**Architecture：** Bash worker 在每次 attempt 状态转换时原子提交 `open` 或 `committed` 状态。Python absolute-deadline supervisor 负责状态目录、process cleanup、验证、timeout 合成和所有固定外部输出。

**Tech Stack：** Bash 3.2-compatible shell、macOS `/usr/bin/python3`、Python `unittest`、GitHub Actions macOS runner。

**Spec：** `docs/superpowers/specs/2026-08-20-macos-assist-diagnostic-atomic-snapshot-design-zh_CN.md`

## 全局约束

- 完整操作（包括 cleanup 和固定输出）只有一个 60 秒 hard deadline。
- Worker 活动在第 58 秒停止，cleanup 最多占用下一秒，最终验证、删除和输出最多占用最后一秒。
- 外部成功输出保持精确的 `ASSIST_STATE=enabled`。
- 现有 19 个诊断字段的名称、数量、顺序和含义保持不变。
- 只有 cleanup 已确认后，才把被中断的 `open` attempt 转换为一次 current response bytes 为 `0` 的 timeout attempt。
- Cleanup-unconfirmed、没有 attempt、状态格式错误、外部 signal 或 finalization deadline 失败均为 generic-only。
- `debug_level=0` 永不打印 `ASSIST_DIAGNOSTIC_*` 字段。
- 原始 CLI stdout/stderr、凭据、custom code、device ID 和其他连接数据绝不进入状态、日志、截图或 artifact。
- 状态目录使用 mode `0700`；状态和临时文件使用 mode `0600`。
- `.github/workflows/macos.yml`、Windows 文件、凭据处理和 artifact schema 不变。
- 先修改英文文档，再同步等义的简体中文文档。
- 每个实施任务都采用 TDD，并在进入下一任务前完成独立 review。

## 实施前 Gate：移除已取代的候选修改

实施 worktree 当前正好包含八个未暂存的 timing-reserve 候选文件。Task 1 前：

1. 获得用户明确授权，丢弃这八个未暂存修改。
2. 将其精确 diff 保存到被忽略的 `.superpowers/` 报告目录中用于审计。
3. 只把以下路径恢复到 committed 状态：
   - `.github/workflows/apple.sh`
   - `docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics.md`
   - `docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md`
   - `docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design.md`
   - `docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md`
   - `tests/macos_assist_allow_harness.sh`
   - `tests/test_agent_work_environment.py`
   - `tests/test_uuremote_desktop_finalization.py`
4. 验证不再存在 `ASSIST_ALLOW_POST_ATTEMPT_RESERVE_MILLISECONDS` 修改，且 tracked worktree clean。

不得使用 `git reset --hard`。不得移除新的原子快照 spec 或本计划。

---

### Task 1：原子诊断状态 contract

**文件：**
- 修改：`.github/workflows/apple.sh:1180-1297`
- 修改：`tests/macos_assist_allow_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py:226-610`

**Interfaces：**
- 产生：`validate_assist_allow_diagnostics <19 values>`；可打印摘要有效时返回 `0`，否则返回 `2`。
- 产生：`validate_assist_diagnostic_state_values <generation> <open|committed> <19 values>`；仅在内部状态转换有效时返回 `0`。
- 产生：`write_assist_diagnostic_state <path> <generation> <open|committed> <19 values>`；仅在原子替换完成后返回 `0`。
- 产生：严格 record `v1<TAB>generation<TAB>state<TAB>19 values<LF>`。

- [ ] **Step 1：编写 source 和 executable failing tests**

新增 portable harness route，source 真实 helper 并写入 caller-owned 临时目录。新增以下测试：

- `test_first_open_state_is_atomic_private_and_strict`：调用 generation `1`、state `open` 和 zero baseline，并断言精确 22 字段、LF framing 和 file mode。
- `test_committed_state_preserves_the_exact_19_value_order`：调用 generation `1`、state `committed`，attempts `1`、enabled-false count `1`、bytes `84/84/84`、category `enabled-false`、exit `0`；断言精确字段位置。
- `test_state_writer_rejects_invalid_generation_state_and_values`：表驱动 generation `0`、`01`、attempts 为 `0` 时的 `2`、state `pending`、负 count、非法 category、total mismatch 和 category/exit mismatch；每个 case 都以非零返回且不替换 baseline file。
- `test_state_writer_failure_leaves_no_partial_record`：分别注入 chmod、write 和 move failure；断言之前的 state bytes 精确不变，且 `${state_path}.tmp` 不存在。
- `test_hostile_payload_markers_never_enter_state_or_output`：只在 fixture payload 中使用 device/custom-code/raw-response marker，并断言每个 marker 都不在 state bytes、stdout 和 stderr 中。

成功的 first-open fixture 必须产生一个以 LF 结尾、含 22 个 tab 分隔字段的 record：generation 为 `1`、state 为 `open`、attempts 为 `0`、所有 count 和 byte value 为 `0`、final category 为 `unavailable`、final exit 为 `unavailable`。断言目录 mode 为 `0700`、state mode 为 `0600`，且返回后没有 `.tmp` 文件。

- [ ] **Step 2：运行 RED**

运行：

```text
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowClassifierTests -v
```

预期：新测试因 validator/state writer route 不存在而失败。

- [ ] **Step 3：将验证与渲染分离**

把 `report_assist_allow_diagnostics` 中现有验证移动到：

创建 `validate_assist_allow_diagnostics`，不削弱地移动当前 `report_assist_allow_diagnostics` 中的以下检查：argument count 为 `19`；非负十进制 counter 和 byte size；允许的 final category 和 exit；attempts 至少为 `1`；每个 category count 不大于 attempts；category total 等于 attempts；`min <= final <= max`；final-category/count 一致性；category/exit 一致性。有效时无输出返回 `0`，无效时返回 `2`。

让 `report_assist_allow_diagnostics` 先调用该 validator，然后逐字节、按当前顺序保留现有 19 条 `printf` statement。

不得削弱任何现有 invariant。新增内部 validator 分支，只允许 `state=open`、generation `1`、attempts `0`、零 counts/bytes 和 `unavailable/unavailable` 作为 first-attempt baseline；外部 reporter 永不接受该分支。

每个非 baseline 状态都复用 printable-value validator。要求 `open` generation 等于 `attempts + 1`；要求 `committed` generation 等于 `attempts`。这些关系使最终 record 本身就能拒绝跳过、重复或不匹配的 generation。

- [ ] **Step 4：实现原子状态写入**

使用以下 boundary：

```bash
write_assist_diagnostic_state() {
    local state_path="$1" generation="$2" state="$3"
    shift 3
    local temporary_path="${state_path}.tmp"

    validate_assist_diagnostic_state_values "$generation" "$state" "$@" || return 1
    umask 077
    : >"$temporary_path" || return 1
    /bin/chmod 0600 "$temporary_path" || {
        /bin/rm -f -- "$temporary_path" 2>/dev/null
        return 1
    }
    {
        printf 'v1\t%s\t%s' "$generation" "$state"
        printf '\t%s' "$@"
        printf '\n'
    } >"$temporary_path" || {
        /bin/rm -f -- "$temporary_path" 2>/dev/null
        return 1
    }
    /bin/mv -f -- "$temporary_path" "$state_path" || {
        /bin/rm -f -- "$temporary_path" 2>/dev/null
        return 1
    }
}
```

State path 与 temporary path 必须位于同一个 supervisor-owned 目录。写入失败时删除临时文件，且绝不改变之前 committed 的状态。

- [ ] **Step 5：运行 GREEN 和 mutation 检查**

运行 focused class。然后运行 isolated-copy mutation，分别移除 `/bin/chmod 0600`、将最终 `/bin/mv` 替换为直接写入、追加 hostile marker。每个 mutation 必须让对应测试失败。

- [ ] **Step 6：Commit**

只暂存三个 Task 1 文件并提交：

```text
feat: add macOS assist diagnostic snapshots
```

请求独立 task review，并在 Task 2 前解决所有 Critical 或 Important finding。

---

### Task 2：Worker 状态转换

**文件：**
- 修改：`.github/workflows/apple.sh:1361-1597,3203-3221`
- 修改：`tests/macos_assist_allow_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py:1630-1979`

**Interfaces：**
- 消费：Task 1 的 `write_assist_diagnostic_state`。
- 产生：`ensure_assist_allowed <state-path>`，不产生最终 stdout/stderr 输出。
- 消费 environment：`assist-allow-worker` mode 中的 `UUREMOTE_ASSIST_INTERNAL_STATE_PATH`。

- [ ] **Step 1：编写 worker transition failing tests**

新增 real-helper scenario 和以下测试：

- `test_worker_commits_open_before_invoking_the_cli`：让 fixture 在进入时读取 state，并要求 generation `1`、state `open`、attempts `0`。
- `test_worker_replaces_open_with_committed_after_classification`：返回一个有效 enabled-false 响应，并要求 generation `1`、state `committed`、attempts `1`、enabled-false count `1`。
- `test_second_open_contains_only_the_previous_committed_aggregate`：阻塞第二次 fixture call，并要求 generation `2`、state `open`、attempts `1`，且只计入第一次 category。
- `test_enabled_true_is_committed_before_worker_success`：让 fixture 返回 enabled-true，在 exit `0` 后检查 final state，并要求 committed enabled-true count `1`。
- `test_open_write_failure_prevents_cli_invocation`：在 attempt one 前让 state move 失败，并要求 CLI call count `0`。
- `test_committed_write_failure_leaves_open_timeout_projection`：允许 open move、让 committed move 失败，并要求 state bytes 保持精确 open record。
- `test_worker_never_prints_the_failure_summary`：在 debug `1` 下运行 committed enabled-false，并要求 worker stdout/stderr 为空。

使用 fixture call counter 证明 `open` 写入失败时不会调用 CLI。分类后受控触发 atomic-replace failure，证明文件保持 `open`。

- [ ] **Step 2：运行 RED**

运行：

```text
python -m unittest tests.test_uuremote_desktop_finalization.MacOSAssistAllowAggregationTests -v
```

预期：失败表明 `ensure_assist_allowed` 尚不接受 state path，也不提交 transition。

- [ ] **Step 3：每次 attempt 前提交 `open`**

调用 `run_bounded_gui_cli_to_file` 前执行：

```bash
generation="$((attempts + 1))"
write_assist_diagnostic_state \
    "$diagnostic_state_path" "$generation" open \
    "$attempts" "$timeout_count" "$cli_nonzero_count" "$empty_count" \
    "$invalid_utf8_count" "$invalid_json_count" "$not_object_count" \
    "$success_missing_count" "$success_wrong_type_count" "$success_false_count" \
    "$enabled_missing_count" "$enabled_wrong_type_count" \
    "$enabled_false_count" "$enabled_true_count" \
    "${response_bytes_min:-0}" "$response_bytes_max" "$response_bytes_final" \
    "$final_category" "$final_cli_exit" || return 1
```

对于 generation `1`，初始内部 baseline 是唯一允许的 `unavailable/unavailable` 状态。

- [ ] **Step 4：严格分类后提交 `committed`**

完成 category accounting 和 byte statistics 后，以等于 `attempts` 的 generation 和 `committed` state 原子写入。只有完成该写入后，`enabled-true` 才能返回成功。

移除 worker 对 `report_assist_allow_diagnostics` 的调用；失败的 worker 以非零退出且不输出最终内容。保留原始 response 清空和 worker 临时树清理。

- [ ] **Step 5：验证内部 entrypoint**

在 `assist-allow-worker` mode 中，严格验证 `UUREMOTE_ASSIST_INTERNAL_STATE_PATH` 是 supervisor-created 目录内的 absolute path；复制到 local variable，并在调用以下命令前 unset environment variable：

```bash
ensure_assist_allowed "$assist_diagnostic_state_path"
```

不得接受缺失、相对、包含 newline 或 NUL 的路径。

- [ ] **Step 6：运行 GREEN 和 causal mutation**

运行 aggregation class 和 CLI redaction entrypoint test。分别 mutation 掉 pre-CLI `open` 写入和 pre-success `committed` 写入；每个 mutation 必须因自己的 behavioral assertion 失败。

- [ ] **Step 7：Commit**

只暂存 Task 2 文件并提交：

```text
refactor: commit macOS assist attempt states
```

请求独立 spec 和 quality review。在 Task 3 前解决 Critical 和 Important finding。

---

### Task 3：Supervisor 验证与固定输出

**文件：**
- 修改：`.github/workflows/apple.sh:1621-2051`
- 修改：`tests/macos_assist_allow_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py:274-610,1119-1629`

**Interfaces：**
- 消费：Task 1 state record 和 Task 2 worker transition。
- 产生 Python helper：`parse_diagnostic_state(path)`、`synthesize_open_timeout(snapshot)`、`render_diagnostics(snapshot)`。
- 产生 supervisor outcome：精确成功、精确 19 字段 debug failure 或 generic-only failure。

- [ ] **Step 1：编写 supervisor failing tests**

新增 portable controlled scenario：

- `test_supervisor_renders_committed_failure_from_state`：提供一个 committed enabled-false record，并要求精确的现有 19 行及 caller generic failure。
- `test_supervisor_synthesizes_open_as_timeout`：提供 first-generation open baseline，并要求 attempts `1`、timeout `1`、bytes `0/0/0` 和 final `timeout/timeout`。
- `test_supervisor_suppresses_diagnostics_at_debug_zero`：在 debug `0` 下复用 committed failure，并要求只存在 caller generic failure。
- `test_supervisor_rejects_malformed_or_missing_state`：表驱动 missing file、额外 LF、CR、NUL、non-ASCII、21/23 字段、非法 generation/state/total；每个 case 都是 generic-only。
- `test_supervisor_rejects_state_until_cleanup_is_confirmed`：在保留有效 committed record 时强制 cleanup result 为 false，并要求 generic-only。
- `test_supervisor_outputs_success_only_from_committed_enabled_true`：只对 exit `0` 加 committed enabled-true 要求精确 success；对 exit `0` 加其他任何 state 都要求 generic-only。
- `test_supervisor_removes_state_before_external_output`：让 state removal 失败并要求 generic-only；成功时让 output probe 验证 state path 和 directory 已不存在。

First-open timeout 的预期值为：attempts `1`、timeout count `1`、其他 count 全部 `0`、byte min/max/final 全部 `0`、final category `timeout`、final exit `timeout`。

- [ ] **Step 2：运行 RED**

运行 supervisor source 和 absolute-deadline class。预期失败必须定位缺失的 parsing/synthesis 和仍存在的 worker-output replay。

- [ ] **Step 3：实现严格 Python parsing**

在现有 supervisor heredoc 中实现：

实现 `parse_diagnostic_state(path)`：只读取一次 bytes；要求恰好一个 terminal LF 且无其他 LF；拆分为精确 22 个 tab-separated fields；要求严格 ASCII decoding、version `v1`、canonical positive generation、state `open|committed` 以及 Task 1 的所有 numeric/enum/aggregate invariant；随后返回 dictionary，keys 为 `generation`、`state`、`attempts`、每个 category count、三个 byte statistic、`final_category` 和 `final_cli_exit`。

实现 `synthesize_open_timeout(snapshot)`：复制该 dictionary，attempts 和 timeout count 精确加一，把 final bytes 设为 `0`，在 min/max 中包含 `0`，把 final category/exit 设为 `timeout`，把 state 改为 `committed`，并在返回前通过同一 value validator。

实现 `render_diagnostics(snapshot)`：返回 ASCII bytes，内容为现有 19 个 `ASSIST_DIAGNOSTIC_*` name、value、order 和 terminal LF。

Parser 必须拒绝 non-ASCII、CR、NUL、额外 whitespace、leading-zero generation、非法 state、非法 total 和 zero-attempt baseline；唯一例外是 state 为 `open` 且 generation 为 `1`。

- [ ] **Step 4：用 state-based finalization 替换 capture replay**

在 supervisor mode-`0700` 目录中创建 state path，初始时不创建可打印 snapshot，并通过 `UUREMOTE_ASSIST_INTERNAL_STATE_PATH` 传给 worker。

将 worker stdout/stderr 与外部日志隔离。Worker 退出或 deadline cleanup 后：

1. 确认所有 owned PID/process group 不存在；
2. parse state；
3. 只对 `open` 合成 timeout；
4. 只有 committed `enabled-true` 才验证为 worker success；
5. 只在 debug `1|2|3` 时 render failure bytes；
6. 在外部输出前删除全部 state、worker 和 temporary data；在 atomic interruption/output decision 完成前，只保留 supervisor decision hard-link；
7. 重新检查 absolute deadline；
8. 原子遵守现有 interruption decision；
9. 打印固定 success 或 diagnostic bytes；
10. 输出原子提交后，在 shell helper 返回前，由 supervisor cleanup trap 删除 decision hard-link 和此时为空的私有目录。

任一步失败都返回 `125` 且不输出结构化内容，使 `enable_assist_or_fail` 只打印 generic failure。

- [ ] **Step 5：设置固定 deadline phase**

使用单一 supervisor deadline：

```python
deadline = time.monotonic() + 60.0
cleanup_start = deadline - 2.0
cleanup_deadline = deadline - 1.0
finalization_deadline = deadline
```

传给 Bash 的 worker cutoff 为 `cleanup_start`。TERM 和 KILL 仍各自最多 500ms。移除 worker finalization-reserve、post-attempt-reserve 常量及其所有 test-only rewrite。

- [ ] **Step 6：运行 GREEN 和 mutation**

运行 focused supervisor/process/aggregation class。分别 mutation cleanup confirmation 为 false、放宽 state parser、绕过 state deletion、移除 debug gate、替换 atomic interruption ownership。每个 mutation 都必须失败且不得泄露 hostile marker。

- [ ] **Step 7：Commit**

只暂存 Task 3 文件并提交：

```text
fix: deliver macOS assist diagnostics atomically
```

请求独立 review，明确聚焦 deadline arithmetic、cleanup ownership、signal race、state validation 和 raw-output privacy。解决所有 Critical 和 Important finding。

---

### Task 4：Targeted native macOS causal gate

**文件：**
- 修改：`tests/macos_assist_allow_harness.sh`
- 修改：`tests/test_uuremote_desktop_finalization.py:1119-1629`

**Interfaces：**
- 消费：真实 production supervisor、worker、state writer、parser 和 cleanup logic。
- 产生：一个与 host provisioning 隔离的 native test class。

- [ ] **Step 1：编写 native failing scenario**

使用 caller-owned temporary root 和真实 production entrypoint 新增以下 Darwin-only tests：

- `test_native_first_open_timeout_is_reported_and_reaped`：在观察到 state `open` 后阻塞第一次 CLI；要求合成 attempt `1` timeout 和严格 release。
- `test_native_committed_then_open_preserves_counts_and_adds_timeout`：先完成一次 enabled-false，再阻塞 attempt two，并要求 attempts `2`、enabled-false `1`、timeout `1`。
- `test_native_committed_failure_outputs_exact_19_fields`：完成一个 non-success category，并要求精确固定输出和 generic caller failure。
- `test_native_cleanup_unconfirmed_is_generic_only`：运行真实 cleanup side effect，强制其 confirmation result 为 false，并要求无 structured field。
- `test_native_enabled_success_is_exact_and_clean`：完成 enabled-true，并要求精确单行 success、空 stderr、空 tree 和 PID/PGID absence。

每个测试必须断言 bounded elapsed time、精确 stdout/stderr、精确字段数量和顺序、temporary root 为空，并在返回前确认所有 recorded PID 和 PGID 不存在。

- [ ] **Step 2：以 causal 方式证明 RED**

针对 isolated source copy 运行 native class，并分别应用以下 mutation：

- 移除 `open` commit；
- 非原子写入 state；
- cleanup confirmation 前接受输出；
- 跳过 open-timeout synthesis；
- 输出前跳过 state removal。

每个 mutation 都必须让专属 assertion 失败。随后未修改实现必须通过全部五个 scenario。

- [ ] **Step 3：移除已取代的 timing diagnostic**

删除已取代的 `absolute-real-poll-summary`、checkpoint counter、classifier delay 和 reserve-budget test route。保留独立有价值的 startup/preexec、clock、poll、signal、cleanup 和 process-group regression。

- [ ] **Step 4：运行本地 portable coverage**

在非 Darwin host 上，确认 native class 被显式 skip，同时 source contract 和 portable state scenario 实际执行。运行 Bash syntax 和 Python compile check。

- [ ] **Step 5：Commit**

只暂存两个测试文件并提交：

```text
test: cover atomic macOS assist finalization
```

请求独立 test-quality review。拒绝 token-only 或 vacuous mutation；所有 native mutation 必须执行真实 production boundary。

---

### Task 5：Governing documentation 与最终本地 gate

**文件：**
- 修改：`docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics.md`
- 修改：`docs/superpowers/plans/2026-08-16-macos-unattended-permission-diagnostics-zh_CN.md`
- 修改：`docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design.md`
- 修改：`docs/superpowers/specs/2026-08-16-macos-unattended-permission-diagnostics-design-zh_CN.md`
- 修改：`tests/test_agent_work_environment.py`

**Interfaces：**
- 消费：Tasks 1-4 的最终 production function name、deadline constant、state schema 和 output rule。
- 产生：meaning-equivalent English/Chinese governing contract 和 executable parity assertion。

- [ ] **Step 1：编写 documentation contract RED tests**

新增 assertion，要求两个语言 pair 都包含：

- supervisor-owned `v1` atomic state；
- `open` 和 `committed` transition；
- 60 秒内的 58 秒 worker、1 秒 cleanup、1 秒 finalization；
- 不变的 19 字段；
- 合成 timeout bytes `0`；
- cleanup-unconfirmed generic-only 行为；
- targeted native 和 full workflow run 分别授权；
- 不存在已取代的 post-attempt 和 worker-report reserve 设计。

新增 semantic mutation，分别从每种语言移除 open-timeout synthesis，并证明每个 counterpart 独立失败。

- [ ] **Step 2：运行 RED**

运行：

```text
python -m unittest tests.test_agent_work_environment -v
```

预期：新 assertion 在旧 governing document 上失败。

- [ ] **Step 3：先更新英文文档，再同步简体中文 counterpart**

将旧 timing-report section 标记为已被 2026-08-20 spec 取代。更新 executable snippet 和 matrix，使其匹配最终 production state schema 和 deadline phase。保持英中文 requirement 等义，并保留 navigation structure。

- [ ] **Step 4：运行 GREEN 和 repository validation**

Fresh 运行：

```text
python -m unittest tests.test_agent_work_environment -v
python -m unittest tests.test_uuremote_desktop_finalization tests.test_uuremote_wait -v
python -m unittest discover -s tests -v
/bin/bash -n .github/workflows/apple.sh tests/macos_assist_allow_harness.sh
git diff --check e30a65b..HEAD
```

在没有 native `/bin/bash` 的 host 上，运行 repository 的 Git Bash syntax-equivalent check，并准确记录 native test skip。只有已知 screenshot test 仅因 sandbox 无 interactive desktop 而失败时，才在获批准的 real-desktop context 中运行一次 full discovery。

同时验证：

- 每个 root 和 `docs/**` Markdown 文件有且仅有一个 counterpart 和有效 navigation；
- 不存在 `-zh_CN-zh_CN.md` path；
- `.claude/settings.json` 可解析且只启用 Superpowers；
- final diff 不包含账户密码、custom code、raw payload、PID/PGID、command line 或新 artifact field；
- `.github/workflows/macos.yml` 和所有 Windows 文件无 diff。

- [ ] **Step 5：Commit documentation contract**

只暂存五个 Task 5 文件并提交：

```text
docs: align macOS assist snapshot contracts
```

- [ ] **Step 6：最终独立 whole-branch review**

从 pre-implementation base 到 HEAD 生成 ignored review package。请求针对已批准 2026-08-20 spec 的 fresh read-only review。解决每个 Critical 和 Important finding，重跑受影响 focused test，然后重跑完整 final gate。不得 push 或 dispatch。

## 实施后的 Remote Gate

Plan approval 不会自动授权 remote action。

1. 获得明确授权后 push reviewed feature branch。
2. 获得明确授权后 dispatch 一次 debug-enabled macOS run。
3. 将现有 `Test device ID logging` step 作为 targeted native gate。监控它；如果 preflight 失败，在 host provisioning 前取消 run，不自动 rerun。
4. 如果每个 targeted atomic-snapshot scenario 都通过，则停止并报告精确 run/job/step 证据。
5. 另行获得明确授权后，运行一次完整 macOS workflow validation。
6. 只接受精确 success 或所要求的固定 19 字段 debug failure；不得出现 raw payload 或 cleanup residue 证据。
7. 任何失败都停止该序列并等待新的 reviewed plan；不得自动 patch、push、rerun、merge 或删除 branch。
