import asyncio
import os
import sys
from pathlib import Path

from TGConvertor import SessionManager

TDATA_CANDIDATES = [
    Path.home() / "Library/Application Support/Telegram Desktop/tdata",
    Path(os.environ.get("APPDATA", "")) / "Telegram Desktop/tdata",
    Path.home() / ".local/share/TelegramDesktop/tdata",
]
OUTPUT = "tg_session.session"


def find_tdata() -> Path:
    for path in TDATA_CANDIDATES:
        if (path / "key_datas").exists():
            return path
    sys.exit("tdata not found: install Telegram Desktop from desktop.telegram.org, log in, quit it, retry")


async def main():
    tdata = find_tdata()
    session = SessionManager.from_tdata_folder(str(tdata))
    await session.to_telethon_file(OUTPUT)
    print(f"ok, dc: {session.dc_id} -> {OUTPUT}")


if __name__ == "__main__":
    asyncio.run(main())
