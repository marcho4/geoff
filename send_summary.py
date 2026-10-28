import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

TOKEN = os.environ["TG_BOT_TOKEN"]
CHAT_ID = os.environ["TG_CHAT_ID"]
LIMIT = 4000  # Telegram limit is 4096 chars per message


def inline(text: str) -> str:
    # Code spans are pulled out first so their contents aren't formatted
    codes = []

    def keep_code(m):
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", keep_code, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)",
                  lambda m: f'<a href="{m.group(2).replace(chr(34), "&quot;")}">{m.group(1)}</a>', text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"~~(.+?)~~", r"<s>\1</s>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", text)
    return re.sub(r"\x00(\d+)\x00",
                  lambda m: f"<code>{html.escape(codes[int(m.group(1))], quote=False)}</code>", text)


def md_to_tg_html(md: str) -> str:
    out, in_code = [], False
    for line in md.splitlines():
        if line.strip().startswith("```"):
            out.append("</pre>" if in_code else "<pre>")
            in_code = not in_code
            continue
        if in_code:
            out.append(html.escape(line, quote=False))
            continue
        if m := re.match(r"#{1,6}\s+(.*)", line):
            out.append(f"<b>{inline(m.group(1))}</b>")
        elif m := re.match(r"(\s*)[-*+]\s+\[([ xX])\]\s+(.*)", line):
            box = "☑" if m.group(2).strip() else "☐"
            out.append(f"{m.group(1)}{box} {inline(m.group(3))}")
        elif m := re.match(r"(\s*)[-*+]\s+(.*)", line):
            bullet = "•" if not m.group(1) else "◦"
            out.append(f"{m.group(1)}{bullet} {inline(m.group(2))}")
        elif re.fullmatch(r"\s*([-*_])\s*(\1\s*){2,}", line):
            out.append("──────────")
        elif m := re.match(r">\s?(.*)", line):
            out.append(f"<blockquote>{inline(m.group(1))}</blockquote>")
        else:
            out.append(inline(line))
    if in_code:
        out.append("</pre>")
    return "\n".join(out)


def split_md(md: str) -> list:
    # Split on blank lines so each chunk is self-contained markdown
    chunks, current = [], ""
    for block in re.split(r"\n\s*\n", md.strip()):
        candidate = f"{current}\n\n{block}" if current else block
        if current and len(md_to_tg_html(candidate)) > LIMIT:
            chunks.append(current)
            current = block
        else:
            current = candidate
    if current:
        chunks.append(current)
    return chunks


def send(text: str, parse_mode=None):
    params = {"chat_id": CHAT_ID, "text": text, "disable_web_page_preview": "true"}
    if parse_mode:
        params["parse_mode"] = parse_mode
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{TOKEN}/sendMessage",
        data=urllib.parse.urlencode(params).encode(),
    )
    urllib.request.urlopen(req, timeout=30).read()


def main(path):
    with open(path, encoding="utf-8") as f:
        md = f.read()
    for chunk in split_md(md):
        try:
            send(md_to_tg_html(chunk), "HTML")
        except urllib.error.HTTPError as e:
            # Malformed HTML entities -> fall back to plain text instead of losing the message
            print(f"HTML rejected ({e.code}: {e.read().decode()}), sending plain text", file=sys.stderr)
            send(chunk[:4096])


if __name__ == "__main__":
    main(sys.argv[1])
