#!/usr/bin/env python3
"""Send a release notification to the bot owner on Telegram.

Usage: tg_notify.py MESSAGE [FILE]
FILE (e.g. a changelog) is appended to MESSAGE. The token comes from
~/.config/telegram-bot.env and the chat from the bot's config.json. Never
fails the caller: problems are printed and the exit code stays 0.
"""
import json
import os
import sys
import urllib.parse
import urllib.request

ENV_FILE = os.path.expanduser("~/.config/telegram-bot.env")
BOT_CONFIG = "/serverhive2/unseenpixel/telegram_bot/config.json"
LIMIT = 4000


def read_token():
    with open(ENV_FILE) as f:
        for line in f:
            if line.startswith("TELEGRAM_BOT_TOKEN="):
                return line.split("=", 1)[1].strip()
    raise RuntimeError(f"no TELEGRAM_BOT_TOKEN in {ENV_FILE}")


def send(token, chat_id, text):
    data = urllib.parse.urlencode({
        "chat_id": chat_id,
        "text": text,
        "disable_web_page_preview": "true",
    }).encode()
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    with urllib.request.urlopen(url, data=data, timeout=20) as r:
        if not json.load(r).get("ok"):
            raise RuntimeError("Telegram refused the message")


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return
    text = sys.argv[1]
    if len(sys.argv) > 2:
        with open(sys.argv[2]) as f:
            text += "\n\n" + f.read().strip()
    try:
        token = read_token()
        chat_id = json.load(open(BOT_CONFIG))["owner_id"]
        for i in range(0, len(text), LIMIT):
            send(token, chat_id, text[i:i + LIMIT])
    except Exception as e:
        print(f"tg_notify: not sent: {e}", file=sys.stderr)


main()
