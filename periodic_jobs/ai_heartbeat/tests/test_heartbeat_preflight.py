from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


TESTS_DIR = Path(__file__).resolve().parent
SRC_DIR = TESTS_DIR.parent / "src" / "v0"
STATE_MODULE_PATH = SRC_DIR / "heartbeat_state.py"
PREFLIGHT_MODULE_PATH = SRC_DIR / "heartbeat_preflight.py"
HOOK_SCRIPT_PATH = TESTS_DIR.parent.parent.parent / ".github" / "hooks" / "pre-session.ps1"

state_spec = importlib.util.spec_from_file_location("heartbeat_state", STATE_MODULE_PATH)
assert state_spec is not None and state_spec.loader is not None
heartbeat_state = importlib.util.module_from_spec(state_spec)
state_spec.loader.exec_module(heartbeat_state)

preflight_spec = importlib.util.spec_from_file_location("heartbeat_preflight", PREFLIGHT_MODULE_PATH)
assert preflight_spec is not None and preflight_spec.loader is not None
heartbeat_preflight = importlib.util.module_from_spec(preflight_spec)
preflight_spec.loader.exec_module(heartbeat_preflight)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


def _write_policy(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")


def _find_powershell() -> str | None:
    return shutil.which("pwsh") or shutil.which("powershell")


def _write_fake_hook_preflight(workspace_root: Path) -> None:
    fake_preflight = workspace_root / "periodic_jobs" / "ai_heartbeat" / "src" / "v0" / "heartbeat_preflight.py"
    fake_preflight.parent.mkdir(parents=True, exist_ok=True)
    fake_preflight.write_text(
        """
import json

print(json.dumps({
    \"title\": \"AI Heartbeat 会前提醒\",
    \"surface\": \"text\",
    \"due_tasks\": [\"observer\", \"reflector\"],
    \"recommended_command\": \"/ai-heartbeat\",
    \"message\": \"AI Heartbeat 提醒：observer、reflector 已过期；方便时请在当前 chat 中运行 /ai-heartbeat。\"
}, ensure_ascii=False))
""".strip(),
        encoding="utf-8",
    )


def _run_pre_session_hook(workspace_root: Path, *, env_updates: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    shell = _find_powershell()
    if shell is None:
        raise SystemExit("PowerShell is required for this test")

    env = os.environ.copy()
    if env_updates:
        env.update(env_updates)

    return subprocess.run(
        [
            shell,
            "-NoProfile",
            "-File",
            str(HOOK_SCRIPT_PATH),
            "-WorkspaceRoot",
            str(workspace_root),
            "-PythonPath",
            sys.executable,
            "-StatePath",
            str(workspace_root / "periodic_jobs" / "ai_heartbeat" / "state" / "heartbeat_status.json"),
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=False,
        env=env,
    )


def test_run_preflight_initializes_missing_state_and_reports_both_tasks(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)

    reminders = heartbeat_preflight.run_preflight(state_path=state_path, now=now)

    assert [item["task"] for item in reminders] == ["observer", "reflector"]
    assert state_path.exists()


def test_run_preflight_respects_same_day_prompt_dedup(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    state = heartbeat_state.default_state()
    state["observer"]["last_prompted_on"] = "2026-05-22"
    state["reflector"]["last_success_at"] = _iso(now - timedelta(days=9))
    heartbeat_state.save_state(state, state_path)

    reminders = heartbeat_preflight.run_preflight(state_path=state_path, now=now)

    assert [item["task"] for item in reminders] == ["reflector"]


def test_mark_prompted_only_updates_prompt_date(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 10, 0, tzinfo=timezone.utc)
    heartbeat_state.save_state(heartbeat_state.default_state(), state_path)

    heartbeat_preflight.mark_prompted(["observer"], state_path=state_path, now=now)

    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["observer"]["last_prompted_on"] == "2026-05-22"
    assert state["observer"]["last_attempt_at"] is None
    assert state["observer"]["last_status"] == "never"


def test_main_prints_human_readable_summary(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    heartbeat_state.save_state(heartbeat_state.default_state(), state_path)
    output = io.StringIO()

    with contextlib.redirect_stdout(output):
        exit_code = heartbeat_preflight.main(["--state-path", str(state_path)])

    rendered = output.getvalue()
    assert exit_code == 0
    assert "observer" in rendered
    assert "reflector" in rendered


def test_run_command_spec_reports_due_tasks_without_marking_prompted(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    heartbeat_state.save_state(heartbeat_state.default_state(), state_path)

    command_spec = heartbeat_preflight.run_command_spec(state_path=state_path, now=now)

    assert command_spec == {
        "due_tasks": ["observer", "reflector"],
        "recommended_action": "observer_and_reflector",
        "target_date": "2026-05-22",
    }

    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["observer"]["last_prompted_on"] is None
    assert state["reflector"]["last_prompted_on"] is None


def test_run_command_spec_uses_local_logical_date_by_default(monkeypatch: object, tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    heartbeat_state.save_state(heartbeat_state.default_state(), state_path)
    local_now = datetime(2026, 5, 30, 0, 30, tzinfo=timezone(timedelta(hours=8)))

    class FakeDateTime(datetime):
        @classmethod
        def now(cls, tz: timezone | None = None) -> datetime:
            if tz is None:
                return local_now
            return local_now.astimezone(tz)

    monkeypatch.setattr(heartbeat_preflight, "datetime", FakeDateTime)

    command_spec = heartbeat_preflight.run_command_spec(state_path=state_path)

    assert command_spec["target_date"] == "2026-05-30"
    assert command_spec["recommended_action"] == "observer_and_reflector"


def test_main_command_spec_prints_json(monkeypatch: object, tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    output = io.StringIO()
    expected = {
        "due_tasks": ["reflector"],
        "recommended_action": "reflector",
        "target_date": "2026-05-22",
    }

    monkeypatch.setattr(heartbeat_preflight, "run_command_spec", lambda **_: expected)

    with contextlib.redirect_stdout(output):
        exit_code = heartbeat_preflight.main(["--command-spec", "--state-path", str(state_path)])

    assert exit_code == 0
    assert json.loads(output.getvalue()) == expected


def test_build_dialog_spec_is_reminder_only(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    state = heartbeat_state.default_state()
    state["observer"]["last_success_at"] = _iso(now - timedelta(hours=1))
    state["reflector"]["last_success_at"] = _iso(now - timedelta(days=8))
    heartbeat_state.save_state(state, state_path)

    reminders = heartbeat_preflight.run_preflight(state_path=state_path, now=now)
    spec = heartbeat_preflight.build_dialog_spec(
        reminders,
        now=now,
        policy={"windows_popup_enabled": True},
    )

    assert [option["label"] for option in spec["options"]] == ["知道了", "今天不再提醒"]
    assert spec["recommended_command"] == "/ai-heartbeat"
    assert "reflector" in spec["question"]
    assert "commands" not in spec
    assert spec["target_date"] == "2026-05-22"


def test_run_hook_dialog_spec_defaults_to_modal_surface_when_policy_missing(
    tmp_path: Path,
    monkeypatch: object,
) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    policy_path = tmp_path / "config" / "reminder_policy.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)

    monkeypatch.setattr(heartbeat_preflight, "REMINDER_POLICY_PATH", policy_path, raising=False)

    dialog_spec = heartbeat_preflight.run_hook_dialog_spec(state_path=state_path, now=now)

    assert dialog_spec is not None
    assert dialog_spec["surface"] == "modal"
    assert [option["label"] for option in dialog_spec["options"]] == ["知道了", "今天不再提醒"]


def test_run_hook_dialog_spec_uses_text_surface_when_popup_disabled(
    tmp_path: Path,
    monkeypatch: object,
) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    policy_path = tmp_path / "config" / "reminder_policy.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    _write_policy(
        policy_path,
        {"windows_popup_enabled": False},
    )

    monkeypatch.setattr(heartbeat_preflight, "REMINDER_POLICY_PATH", policy_path, raising=False)

    dialog_spec = heartbeat_preflight.run_hook_dialog_spec(state_path=state_path, now=now)

    assert dialog_spec is not None
    assert dialog_spec["surface"] == "text"
    assert dialog_spec.get("options", []) == []
    assert "/ai-heartbeat" in dialog_spec["question"]
    assert "运行 /ai-heartbeat：补记今天的新变化，整理近期记忆" in dialog_spec["question"]
    assert "作用：让后续协作与 agent 接续更稳" in dialog_spec["question"]


def test_run_hook_dialog_spec_falls_back_to_modal_surface_when_policy_is_invalid(
    tmp_path: Path,
    monkeypatch: object,
) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    policy_path = tmp_path / "config" / "reminder_policy.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    policy_path.parent.mkdir(parents=True, exist_ok=True)
    policy_path.write_text("{not-json", encoding="utf-8")

    monkeypatch.setattr(heartbeat_preflight, "REMINDER_POLICY_PATH", policy_path, raising=False)

    dialog_spec = heartbeat_preflight.run_hook_dialog_spec(state_path=state_path, now=now)

    assert dialog_spec is not None
    assert dialog_spec["surface"] == "modal"


def test_load_reminder_policy_only_uses_popup_boolean(tmp_path: Path) -> None:
    policy_path = tmp_path / "config" / "reminder_policy.json"
    _write_policy(
        policy_path,
        {
            "windows_popup_enabled": False,
            "legacy_surface": "text",
            "legacy_ui_profile": {"modal": "direct", "text": "gentle"},
        },
    )

    policy = heartbeat_preflight.load_reminder_policy(policy_path)

    assert policy == {"windows_popup_enabled": False}


def test_run_command_spec_is_not_affected_by_reminder_policy(
    tmp_path: Path,
    monkeypatch: object,
) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    policy_path = tmp_path / "config" / "reminder_policy.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    _write_policy(
        policy_path,
        {"windows_popup_enabled": False},
    )

    monkeypatch.setattr(heartbeat_preflight, "REMINDER_POLICY_PATH", policy_path, raising=False)
    heartbeat_state.save_state(heartbeat_state.default_state(), state_path)

    command_spec = heartbeat_preflight.run_command_spec(state_path=state_path, now=now)

    assert command_spec == {
        "due_tasks": ["observer", "reflector"],
        "recommended_action": "observer_and_reflector",
        "target_date": "2026-05-22",
    }


def test_pre_session_hook_uses_light_reminder_branch_for_text_surface(tmp_path: Path) -> None:
    workspace_root = tmp_path / "workspace"
    _write_fake_hook_preflight(workspace_root)
    event_log_path = tmp_path / "events.log"

    result = _run_pre_session_hook(
        workspace_root,
        env_updates={
            "AI_HEARTBEAT_TEST_DISABLE_UI": "1",
            "AI_HEARTBEAT_TEST_EVENT_LOG": str(event_log_path),
        },
    )

    assert result.returncode == 0
    assert result.stdout.strip() == ""
    assert event_log_path.read_text(encoding="utf-8").splitlines() == [
        "text_reminder_shown",
        "text_reminder_duration_ms:8880",
        "text_reminder_auto_closed",
    ]


def test_pre_session_hook_copies_command_when_light_reminder_is_clicked(tmp_path: Path) -> None:
    workspace_root = tmp_path / "workspace"
    _write_fake_hook_preflight(workspace_root)
    event_log_path = tmp_path / "events.log"
    clipboard_log_path = tmp_path / "clipboard.log"

    result = _run_pre_session_hook(
        workspace_root,
        env_updates={
            "AI_HEARTBEAT_TEST_DISABLE_UI": "1",
            "AI_HEARTBEAT_TEST_EVENT_LOG": str(event_log_path),
            "AI_HEARTBEAT_TEST_CLIPBOARD_LOG": str(clipboard_log_path),
            "AI_HEARTBEAT_TEST_SIMULATE_CLICK": "1",
        },
    )

    assert result.returncode == 0
    assert event_log_path.read_text(encoding="utf-8").splitlines() == [
        "text_reminder_shown",
        "text_reminder_duration_ms:8880",
        "text_reminder_clicked",
    ]
    assert clipboard_log_path.read_text(encoding="utf-8") == "/ai-heartbeat"


def test_run_hook_returns_message_without_marking_prompted(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)

    message = heartbeat_preflight.run_hook(state_path=state_path, now=now)

    assert message is not None
    assert "AI Heartbeat 会前提醒" in message
    assert "observer" in message
    assert "reflector" in message
    assert "/ai-heartbeat" in message
    assert "当前 chat" in message
    assert "heartbeat_local_runner.py" not in message
    assert ".\\.venv\\Scripts\\python.exe" not in message

    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["observer"]["last_prompted_on"] is None
    assert state["reflector"]["last_prompted_on"] is None


def test_run_hook_uses_local_logical_date_by_default_without_marking_prompted(monkeypatch: object, tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    local_now = datetime(2026, 5, 30, 0, 30, tzinfo=timezone(timedelta(hours=8)))

    class FakeDateTime(datetime):
        @classmethod
        def now(cls, tz: timezone | None = None) -> datetime:
            if tz is None:
                return local_now
            return local_now.astimezone(tz)

    monkeypatch.setattr(heartbeat_preflight, "datetime", FakeDateTime)

    message = heartbeat_preflight.run_hook(state_path=state_path)

    assert message is not None
    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["observer"]["last_prompted_on"] is None
    assert state["reflector"]["last_prompted_on"] is None


def test_run_hook_dialog_spec_returns_payload_without_marking_prompted(
    tmp_path: Path,
    monkeypatch: object,
) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    policy_path = tmp_path / "config" / "reminder_policy.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)

    monkeypatch.setattr(heartbeat_preflight, "REMINDER_POLICY_PATH", policy_path, raising=False)

    dialog_spec = heartbeat_preflight.run_hook_dialog_spec(state_path=state_path, now=now)

    assert dialog_spec is not None
    assert dialog_spec["due_tasks"] == ["observer", "reflector"]
    assert dialog_spec["target_date"] == "2026-05-22"
    assert dialog_spec["recommended_command"] == "/ai-heartbeat"
    assert [option["label"] for option in dialog_spec["options"]] == ["知道了", "今天不再提醒"]

    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["observer"]["last_prompted_on"] is None
    assert state["reflector"]["last_prompted_on"] is None


def test_run_command_spec_still_reports_due_tasks_after_same_day_hook_prompt(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)

    heartbeat_preflight.mark_prompted(["observer", "reflector"], state_path=state_path, now=now)

    command_spec = heartbeat_preflight.run_command_spec(state_path=state_path, now=now)
    assert command_spec == {
        "due_tasks": ["observer", "reflector"],
        "recommended_action": "observer_and_reflector",
        "target_date": "2026-05-22",
    }
    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["observer"]["last_prompted_on"] == "2026-05-22"
    assert state["reflector"]["last_prompted_on"] == "2026-05-22"


def test_run_command_spec_treats_same_day_skipped_observer_as_handled(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 30, 9, 0, tzinfo=timezone(timedelta(hours=8)))
    state = heartbeat_state.default_state()

    heartbeat_state.record_skipped(
        state,
        "observer",
        now=now,
        target_date="2026-05-30",
    )
    heartbeat_state.record_success(
        state,
        "reflector",
        now=now,
        target_date="2026-05-30",
    )
    heartbeat_state.save_state(state, state_path)

    command_spec = heartbeat_preflight.run_command_spec(state_path=state_path, now=now)

    assert command_spec == {
        "due_tasks": [],
        "recommended_action": "none",
        "target_date": "2026-05-30",
    }


def test_hook_dialog_spec_mode_dedups_same_day(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    state = heartbeat_state.default_state()
    state["observer"]["last_prompted_on"] = "2026-05-22"
    state["reflector"]["last_prompted_on"] = "2026-05-22"
    heartbeat_state.save_state(state, state_path)

    dialog_spec = heartbeat_preflight.run_hook_dialog_spec(state_path=state_path, now=now)

    assert dialog_spec is None


def test_hook_message_omits_irrelevant_actions_for_single_due_task(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    state = heartbeat_state.default_state()
    state["observer"]["last_success_at"] = _iso(now - timedelta(hours=1))
    state["reflector"]["last_success_at"] = _iso(now - timedelta(days=8))
    heartbeat_state.save_state(state, state_path)

    message = heartbeat_preflight.run_hook(state_path=state_path, now=now)
    assert message is not None
    assert "reflector" in message
    assert "/ai-heartbeat" in message
    assert "heartbeat_local_runner.py" not in message
