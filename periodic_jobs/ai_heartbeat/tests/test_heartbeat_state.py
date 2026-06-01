from __future__ import annotations

import importlib.util
from datetime import datetime, timedelta, timezone
from pathlib import Path


TESTS_DIR = Path(__file__).resolve().parent
MODULE_PATH = TESTS_DIR.parent / "src" / "v0" / "heartbeat_state.py"
SPEC = importlib.util.spec_from_file_location("heartbeat_state", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
heartbeat_state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(heartbeat_state)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat()


def test_default_state_matches_schema() -> None:
    state = heartbeat_state.default_state()

    assert state["version"] == 1
    assert set(state.keys()) == {"version", "observer", "reflector"}
    assert state["observer"] == {
        "last_success_at": None,
        "last_attempt_at": None,
        "last_status": "never",
        "last_target_date": None,
        "last_error": None,
        "last_prompted_on": None,
    }
    assert state["reflector"] == state["observer"]


def test_task_due_respects_intervals() -> None:
    now = datetime(2026, 5, 22, 12, 0, tzinfo=timezone.utc)
    state = heartbeat_state.default_state()
    state["observer"]["last_success_at"] = _iso(now - timedelta(hours=25))
    state["reflector"]["last_success_at"] = _iso(now - timedelta(days=6, hours=23))

    assert heartbeat_state.task_is_due(state, "observer", now=now) is True
    assert heartbeat_state.task_is_due(state, "reflector", now=now) is False


def test_collect_due_tasks_skips_same_day_prompt() -> None:
    now = datetime(2026, 5, 22, 9, 0, tzinfo=timezone.utc)
    state = heartbeat_state.default_state()
    state["observer"]["last_prompted_on"] = "2026-05-22"
    state["reflector"]["last_success_at"] = _iso(now - timedelta(days=8))
    state["reflector"]["last_prompted_on"] = "2026-05-21"

    reminders = heartbeat_state.collect_due_tasks(state, now=now)

    assert [item["task"] for item in reminders] == ["reflector"]


def test_load_state_recovers_from_corrupt_json(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"
    state_path.write_text("{not valid json", encoding="utf-8")

    state = heartbeat_state.load_or_init_state(state_path)

    assert state == heartbeat_state.default_state()
    backups = list(tmp_path.glob("heartbeat_status.corrupt-*.json"))
    assert len(backups) == 1
    assert state_path.exists()


def test_record_status_updates_expected_fields() -> None:
    now = datetime(2026, 5, 22, 15, 30, tzinfo=timezone.utc)
    state = heartbeat_state.default_state()

    heartbeat_state.record_prompted(state, "observer", now=now)
    assert state["observer"]["last_prompted_on"] == "2026-05-22"
    assert state["observer"]["last_attempt_at"] is None

    heartbeat_state.record_failure(
        state,
        "observer",
        now=now,
        error="network timeout",
        target_date="2026-05-22",
    )
    assert state["observer"]["last_status"] == "failed"
    assert state["observer"]["last_error"] == "network timeout"
    assert state["observer"]["last_target_date"] == "2026-05-22"
    assert state["observer"]["last_prompted_on"] == "2026-05-22"

    heartbeat_state.record_success(
        state,
        "observer",
        now=now,
        target_date="2026-05-22",
    )
    assert state["observer"]["last_status"] == "success"
    assert state["observer"]["last_success_at"] == _iso(now)
    assert state["observer"]["last_error"] is None
    assert state["observer"]["last_prompted_on"] == "2026-05-22"

    heartbeat_state.record_skipped(
        state,
        "reflector",
        now=now,
        target_date="2026-05-22",
    )
    assert state["reflector"]["last_status"] == "skipped"
    assert state["reflector"]["last_success_at"] is None
    assert state["reflector"]["last_target_date"] == "2026-05-22"
    assert state["reflector"]["last_prompted_on"] == "2026-05-22"