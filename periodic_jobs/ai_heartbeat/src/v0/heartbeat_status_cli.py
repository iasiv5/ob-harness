from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Sequence


MODULE_DIR = Path(__file__).resolve().parent
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

import heartbeat_state


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Update AI Heartbeat task status from local Copilot execution")
    parser.add_argument("task", choices=tuple(heartbeat_state.TASK_INTERVALS.keys()))
    parser.add_argument("--status", required=True, choices=("success", "failed", "skipped"))
    parser.add_argument("--target-date")
    parser.add_argument("--error")
    parser.add_argument("--state-path")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.status == "success":
        heartbeat_state.persist_success(args.task, path=args.state_path, target_date=args.target_date)
        print(f"Recorded success for {args.task}")
        return 0

    if args.status == "skipped":
        heartbeat_state.persist_skipped(args.task, path=args.state_path, target_date=args.target_date)
        print(f"Recorded skipped for {args.task}")
        return 0

    heartbeat_state.persist_failure(
        args.task,
        path=args.state_path,
        target_date=args.target_date,
        error=args.error,
    )
    print(f"Recorded failure for {args.task}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())