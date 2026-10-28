import email
import imaplib
import json
import os
from datetime import datetime, timedelta, timezone
from email.header import decode_header, make_header
from email.message import Message

LOGIN = os.environ["YANDEX_LOGIN"]
APP_PASSWORD = os.environ["YANDEX_APP_PASSWORD"]
HOURS_BACK = int(os.environ.get("HOURS_BACK", "24"))
OUTPUT_PATH = os.environ.get("MAIL_OUTPUT", "yandex_mail_export.json")
IMAP_HOST = "imap.yandex.ru"
BODY_LIMIT = 3000


def connect():
    client = imaplib.IMAP4_SSL(IMAP_HOST)
    client.login(LOGIN, APP_PASSWORD)
    client.select("INBOX", readonly=True)
    return client


def recent_message_ids(client, cutoff):
    since = cutoff.strftime("%d-%b-%Y")
    _, data = client.search(None, "SINCE", since)
    return data[0].split()


def fetch_message(client, message_id) -> Message:
    _, data = client.fetch(message_id, "(BODY.PEEK[])")
    return email.message_from_bytes(data[0][1])


def decode(value) -> str:
    return str(make_header(decode_header(value or "")))


def text_body(message: Message) -> str:
    parts = message.walk() if message.is_multipart() else [message]
    for part in parts:
        if part.get_content_type() == "text/plain":
            payload = part.get_payload(decode=True)
            charset = part.get_content_charset() or "utf-8"
            return payload.decode(charset, errors="replace")
    return ""


def message_date(message: Message):
    date = email.utils.parsedate_to_datetime(message["Date"])
    if date.tzinfo is None:
        date = date.replace(tzinfo=timezone.utc)
    return date


def to_record(message: Message) -> dict:
    return {
        "date": message_date(message).isoformat(),
        "from": decode(message["From"]),
        "subject": decode(message["Subject"]),
        "body": text_body(message).strip()[:BODY_LIMIT],
    }


def export_mail():
    cutoff = datetime.now(timezone.utc) - timedelta(hours=HOURS_BACK)
    client = connect()
    try:
        messages = [fetch_message(client, mid) for mid in recent_message_ids(client, cutoff)]
    finally:
        client.logout()
    records = [to_record(m) for m in messages if message_date(m) >= cutoff]
    records.sort(key=lambda r: r["date"])
    return {"exported_at": datetime.now(timezone.utc).isoformat(), "messages": records}


def save_json(data, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def main():
    data = export_mail()
    save_json(data, OUTPUT_PATH)
    print(f"Saved {len(data['messages'])} messages to {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
