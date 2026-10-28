import asyncio
import json
import os
import sys
from datetime import datetime, timedelta, timezone

from telethon import TelegramClient, functions, utils

API_ID = int(os.environ["TG_API_ID"])
API_HASH = os.environ["TG_API_HASH"]
FOLDER_NAME = os.environ.get("TG_FOLDER", "HSE")
SESSION_PATH = os.environ.get("TG_SESSION", "tg_session")
HOURS_BACK = int(os.environ.get("HOURS_BACK", "24"))
OUTPUT_PATH = os.environ.get("TG_OUTPUT", "telegram_export.json")


def filter_title(dialog_filter) -> str:
    title = getattr(dialog_filter, "title", "")
    return getattr(title, "text", title)


async def find_folder(client, name):
    result = await client(functions.messages.GetDialogFiltersRequest())
    filters = getattr(result, "filters", result)
    for dialog_filter in filters:
        if filter_title(dialog_filter) == name:
            return dialog_filter
    raise SystemExit(f"Folder '{name}' not found")


def folder_peer_ids(dialog_filter) -> set:
    peers = list(dialog_filter.include_peers) + list(dialog_filter.pinned_peers)
    return {utils.get_peer_id(peer) for peer in peers}


async def folder_dialogs(client, dialog_filter):
    wanted = folder_peer_ids(dialog_filter)
    return [d async for d in client.iter_dialogs() if d.id in wanted]


def sender_name(sender) -> str:
    if sender is None:
        return "unknown"
    return getattr(sender, "title", None) or " ".join(
        part for part in (sender.first_name, sender.last_name) if part
    )


async def recent_messages(client, dialog, cutoff):
    messages = []
    async for message in client.iter_messages(dialog.entity):
        if message.date < cutoff:
            break
        if not message.text:
            continue
        sender = await message.get_sender()
        messages.append({
            "date": message.date.isoformat(),
            "sender": sender_name(sender),
            "text": message.text,
        })
    messages.reverse()
    return messages


async def export_folder():
    cutoff = datetime.now(timezone.utc) - timedelta(hours=HOURS_BACK)
    async with TelegramClient(SESSION_PATH, API_ID, API_HASH) as client:
        dialog_filter = await find_folder(client, FOLDER_NAME)
        dialogs = await folder_dialogs(client, dialog_filter)
        chats = []
        for dialog in dialogs:
            messages = await recent_messages(client, dialog, cutoff)
            if messages:
                chats.append({"chat": dialog.name, "messages": messages})
    return {"exported_at": datetime.now(timezone.utc).isoformat(), "chats": chats}


def save_json(data, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def main():
    data = asyncio.run(export_folder())
    save_json(data, OUTPUT_PATH)
    total = sum(len(chat["messages"]) for chat in data["chats"])
    print(f"Saved {total} messages from {len(data['chats'])} chats to {OUTPUT_PATH}")


if __name__ == "__main__":
    sys.exit(main())
