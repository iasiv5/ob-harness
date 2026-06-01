from __future__ import annotations

import importlib.util
import json
from pathlib import Path


TESTS_DIR = Path(__file__).resolve().parent
SRC_DIR = TESTS_DIR.parent / "src" / "v0"
CLI_MODULE_PATH = SRC_DIR / "heartbeat_status_cli.py"

cli_spec = importlib.util.spec_from_file_location("heartbeat_status_cli", CLI_MODULE_PATH)
assert cli_spec is not None and cli_spec.loader is not None
heartbeat_status_cli = importlib.util.module_from_spec(cli_spec)
cli_spec.loader.exec_module(heartbeat_status_cli)


def test_cli_records_success(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"

    exit_code = heartbeat_status_cli.main(
        [
            "observer",
            "--status",
            "success",
            "--target-date",
            "2026-05-22",
            "--state-path",
            str(state_path),
        ]
    )

    assert exit_code == 0
    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["observer"]["last_status"] == "success"
    assert state["observer"]["last_target_date"] == "2026-05-22"


def test_cli_records_failure(tmp_path: Path) -> None:
    state_path = tmp_path / "heartbeat_status.json"

    exit_code = heartbeat_status_cli.main(
        [
            "reflector",
            "--status",
            "failed",
            "--target-date",
            "2026-05-22",
            "--error",
            "missing local context",
            "--state-path",
            str(state_path),
        ]
    )

    assert exit_code == 0
    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["reflector"]["last_status"] == "failed"
    assert state["reflector"]["last_target_date"] == "2026-05-22"
    assert state["reflector"]["last_error"] == "missing local context"