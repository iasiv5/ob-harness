from __future__ import annotations

import json
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Any


HEARTBEAT_ROOT = Path(__file__).resolve().parents[2]
STATE_DIR = HEARTBEAT_ROOT / "state"
STATE_PATH = STATE_DIR / "heartbeat_status.json"
TASK_INTERVALS = {
    "observer": timedelta(hours=24),
    "reflector": timedelta(days=7),
}


def _default_task_state() -> dict[str, Any]:
    return {
        "last_success_at": None,
        "last_attempt_at": None,
        "last_status": "never",
        "last_target_date": None,
        "last_error": None,
        "last_prompted_on": None,
    }


def default_state() -> dict[str, Any]:
    return {
        "version": 1,
        "observer": _default_task_state(),
        "reflector": _default_task_state(),
    }


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def local_now() -> datetime:
    return datetime.now().astimezone()


def _coerce_now(now: datetime | None = None) -> datetime:
    current_time = now or local_now()
    if current_time.tzinfo is None:
        return current_time.astimezone()
    return current_time


def _resolve_path(path: str | Path | None = None) -> Path:
    return Path(path) if path is not None else STATE_PATH


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _serialize_datetime(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat()


def _deserialize_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    _ensure_parent(path)
    with NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temp_path = Path(handle.name)
    temp_path.replace(path)


def save_state(state: dict[str, Any], path: str | Path | None = None) -> Path:
    target = _resolve_path(path)
    _atomic_write_json(target, state)
    return target


def _backup_corrupt_file(path: Path) -> Path:
    timestamp = utc_now().strftime("%Y%m%d%H%M%S")
    backup_path = path.with_name(f"{path.stem}.corrupt-{timestamp}{path.suffix}")
    path.replace(backup_path)
    return backup_path


def _normalize_state(payload: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ValueError("Heartbeat state payload must be a JSON object")

    normalized = default_state()
    version = payload.get("version")
    if isinstance(version, int):
        normalized["version"] = version

    for task_name in TASK_INTERVALS:
        candidate = payload.get(task_name)
        if not isinstance(candidate, dict):
            continue
        task_state = normalized[task_name]
        for field_name in task_state:
            if field_name in candidate:
                task_state[field_name] = candidate[field_name]

    return normalized


def load_or_init_state(path: str | Path | None = None) -> dict[str, Any]:
    target = _resolve_path(path)
    if not target.exists():
        state = default_state()
        save_state(state, target)
        return state

    try:
        payload = json.loads(target.read_text(encoding="utf-8"))
        state = _normalize_state(payload)
    except (OSError, json.JSONDecodeError, ValueError):
        _backup_corrupt_file(target)
        state = default_state()
        save_state(state, target)
        return state

    # Backfill missing fields and version changes in-place.
    save_state(state, target)
    return state


def task_is_due(state: dict[str, Any], task_name: str, now: datetime | None = None) -> bool:
    if task_name not in TASK_INTERVALS:
        raise KeyError(f"Unknown heartbeat task: {task_name}")

    current_time = _coerce_now(now)
    last_success_at = _deserialize_datetime(state[task_name].get("last_success_at"))
    if last_success_at is None:
        return True

    return current_time - last_success_at > TASK_INTERVALS[task_name]


def collect_due_tasks(
    state: dict[str, Any],
    now: datetime | None = None,
    *,
    respect_prompted: bool = True,
) -> list[dict[str, Any]]:
    current_time = _coerce_now(now)
    today = current_time.date().isoformat()
    reminders: list[dict[str, Any]] = []

    for task_name in TASK_INTERVALS:
        task_state = state[task_name]
        if task_state.get("last_target_date") == today and task_state.get("last_status") in {"success", "skipped"}:
            continue
        if not task_is_due(state, task_name, now=current_time):
            continue
        if respect_prompted and task_state.get("last_prompted_on") == today:
            continue

        last_success_at = _deserialize_datetime(task_state.get("last_success_at"))
        due_after = TASK_INTERVALS[task_name]
        overdue_by = None
        if last_success_at is not None:
            overdue_by = current_time - last_success_at - due_after

        reminders.append(
            {
                "task": task_name,
                "last_success_at": task_state.get("last_success_at"),
                "last_prompted_on": task_state.get("last_prompted_on"),
                "overdue_by": overdue_by,
            }
        )

    return reminders


def _mutate_task_state(
    state: dict[str, Any],
    task_name: str,
    *,
    now: datetime | None = None,
    target_date: str | None = None,
) -> tuple[dict[str, Any], datetime]:
    if task_name not in TASK_INTERVALS:
        raise KeyError(f"Unknown heartbeat task: {task_name}")

    current_time = _coerce_now(now)
    task_state = state[task_name]
    if target_date is not None:
        task_state["last_target_date"] = target_date
    return task_state, current_time


def _resolve_prompted_on(current_time: datetime, target_date: str | None = None) -> str:
    return target_date or current_time.date().isoformat()


def record_prompted(state: dict[str, Any], task_name: str, now: datetime | None = None) -> dict[str, Any]:
    task_state, current_time = _mutate_task_state(state, task_name, now=now)
    task_state["last_prompted_on"] = current_time.date().isoformat()
    return state


def record_failure(
    state: dict[str, Any],
    task_name: str,
    *,
    now: datetime | None = None,
    error: str | None = None,
    target_date: str | None = None,
) -> dict[str, Any]:
    task_state, current_time = _mutate_task_state(state, task_name, now=now, target_date=target_date)
    task_state["last_attempt_at"] = _serialize_datetime(current_time)
    task_state["last_status"] = "failed"
    task_state["last_error"] = error
    task_state["last_prompted_on"] = _resolve_prompted_on(current_time, target_date)
    return state


def record_success(
    state: dict[str, Any],
    task_name: str,
    *,
    now: datetime | None = None,
    target_date: str | None = None,
) -> dict[str, Any]:
    task_state, current_time = _mutate_task_state(state, task_name, now=now, target_date=target_date)
    serialized_now = _serialize_datetime(current_time)
    task_state["last_attempt_at"] = serialized_now
    task_state["last_success_at"] = serialized_now
    task_state["last_status"] = "success"
    task_state["last_error"] = None
    task_state["last_prompted_on"] = _resolve_prompted_on(current_time, target_date)
    return state


def record_skipped(
    state: dict[str, Any],
    task_name: str,
    *,
    now: datetime | None = None,
    target_date: str | None = None,
) -> dict[str, Any]:
    task_state, current_time = _mutate_task_state(state, task_name, now=now, target_date=target_date)
    task_state["last_attempt_at"] = _serialize_datetime(current_time)
    task_state["last_status"] = "skipped"
    task_state["last_error"] = None
    task_state["last_prompted_on"] = _resolve_prompted_on(current_time, target_date)
    return state


def persist_prompted(task_name: str, *, path: str | Path | None = None, now: datetime | None = None) -> dict[str, Any]:
    state = load_or_init_state(path)
    record_prompted(state, task_name, now=now)
    save_state(state, path)
    return state


def persist_failure(
    task_name: str,
    *,
    path: str | Path | None = None,
    now: datetime | None = None,
    error: str | None = None,
    target_date: str | None = None,
) -> dict[str, Any]:
    state = load_or_init_state(path)
    record_failure(state, task_name, now=now, error=error, target_date=target_date)
    save_state(state, path)
    return state


def persist_success(
    task_name: str,
    *,
    path: str | Path | None = None,
    now: datetime | None = None,
    target_date: str | None = None,
) -> dict[str, Any]:
    state = load_or_init_state(path)
    record_success(state, task_name, now=now, target_date=target_date)
    save_state(state, path)
    return state


def persist_skipped(
    task_name: str,
    *,
    path: str | Path | None = None,
    now: datetime | None = None,
    target_date: str | None = None,
) -> dict[str, Any]:
    state = load_or_init_state(path)
    record_skipped(state, task_name, now=now, target_date=target_date)
    save_state(state, path)
    return state