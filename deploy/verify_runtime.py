"""Check live integrations or the running service without sending test messages."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from dotenv import dotenv_values, load_dotenv


def check_service(wait: float) -> None:
    deadline = time.monotonic() + wait
    while True:
        result = subprocess.run(
            ["systemctl", "show", "workana-bot", "-p", "ActiveState", "-p", "SubState",
             "-p", "MainPID", "-p", "UnitFileState", "-p", "NRestarts"],
            text=True, capture_output=True, check=True,
        )
        status = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        pid = status.get("MainPID", "0")
        live = status.get("ActiveState") == "active" and pid != "0" and Path(f"/proc/{pid}").is_dir()
        records = subprocess.check_output(
            ["journalctl", "-u", "workana-bot", f"_PID={pid}", "-b", "-n", "300", "-o", "json", "--no-pager"],
            text=True,
        )
        messages = [json.loads(line).get("MESSAGE", "") for line in records.splitlines() if line.startswith("{")]
        ready = any("Bootstrap complete" in message for message in messages)
        if live and ready and status.get("UnitFileState") == "enabled":
            state = json.loads(Path("/var/lib/workana-bot/seen_jobs.json").read_text(encoding="utf-8"))
            status["seen_jobs"] = len(state["slugs"])
            print(json.dumps(status, indent=2))
            print("PASS: service is running, enabled at boot, and has fetched jobs and sent its startup message.")
            return
        if time.monotonic() >= deadline:
            print(json.dumps(status, indent=2))
            raise RuntimeError("Service has not completed a successful fetch and startup message; inspect its journal.")
        time.sleep(2)


async def check_live() -> None:
    from config import Settings
    from telegram import Bot
    from workana import WorkanaFetchConfig, configure_workana_fetch, fetch_recent_jobs

    settings = Settings.from_env()
    configure_workana_fetch(WorkanaFetchConfig(
        use_playwright=settings.workana_use_playwright,
        playwright_fallback=settings.workana_playwright_fallback,
        remote_fetch_url=settings.workana_remote_fetch_url,
        remote_fetch_secret=settings.workana_remote_fetch_secret,
        proxy=settings.workana_proxy,
    ))
    async with Bot(settings.telegram_bot_token) as bot:
        identity = await bot.get_me()
        chat = await bot.get_chat(settings.telegram_chat_id)
        if chat.type == "channel":
            member = await bot.get_chat_member(chat.id, identity.id)
            if member.status != "creator" and not getattr(member, "can_post_messages", False):
                raise RuntimeError("The Telegram bot needs permission to post in the configured channel.")
        print("PASS: Telegram credentials and chat access" + (", channel posting permitted." if chat.type == "channel" else "."))

    jobs = await fetch_recent_jobs(settings.workana_jobs_url)
    matches = sum(job.matches_keywords(settings.keywords) and job.matches_max_bids(settings.max_bids) for job in jobs)
    print(f"PASS: Workana live fetch parsed {len(jobs)} jobs, {matches} match the configured filters.")
    if jobs:
        from bot import format_job_message, job_link_keyboard

        assert format_job_message(jobs[0])
        assert job_link_keyboard(jobs[0]).to_dict()["inline_keyboard"]
        print("PASS: live job renders as a Telegram alert with link buttons.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--live", action="store_true")
    mode.add_argument("--service", action="store_true")
    parser.add_argument("--env-file", type=Path, default=Path("/etc/workana-bot.env"))
    parser.add_argument("--wait", type=float, default=0)
    args = parser.parse_args()
    load_dotenv(args.env_file)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    try:
        if args.service:
            check_service(args.wait)
        else:
            asyncio.run(check_live())
        return 0
    except Exception as exc:
        message = f"FAIL: {type(exc).__name__}: {exc}"
        for key, value in dotenv_values(args.env_file).items():
            if value and any(word in key for word in ("TOKEN", "SECRET", "PROXY")):
                message = message.replace(value, "[redacted]")
        for key in ("TELEGRAM_BOT_TOKEN", "WORKANA_REMOTE_FETCH_SECRET", "WORKANA_PROXY"):
            value = os.environ.get(key)
            if value:
                message = message.replace(value, "[redacted]")
        print(message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
