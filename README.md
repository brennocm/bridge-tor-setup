# bridge-tor-setup

One script (`setup.sh`) that prepares a Debian VPS from scratch and runs a Tor obfs4 bridge with monitoring: basic hardening, Docker, the official Tor Project bridge, Uptime Kuma and a daily summary on Telegram.

A bridge helps people in countries that block Tor to connect. Unlike a relay, it does not appear in the network's public list.

## What it does

1. Updates the system and installs the essential packages.
2. Configures the firewall (UFW), fail2ban, kernel hardening, automatic security updates, time sync and swap.
3. Installs Docker and applies the **ufw-docker** fix (without it, Docker ignores the UFW rules).
4. Clones the official bridge repository (Tor Project) and writes a `docker-compose.yml` with the three services.
5. On the first run, writes a `.env` with placeholders and **stops**, waiting for you to fill it in.
6. On the second run, starts the stack and tries to capture the bridge fingerprint automatically.

## Usage

Run it as root:

```bash
# 1st run: creates the .env
bash setup.sh

# fill in the .env with your real values (fields below)
nano /opt/tor-bridge-stack/.env

# 2nd run: starts the stack
bash setup.sh
```

You can run it again as often as you need: steps that are already done are skipped (repository clone, swap creation and so on).

## `.env` fields

| Field | What it is | Note |
|---|---|---|
| `OR_PORT` / `PT_PORT` | Bridge ports | Default 9001/9002; only change them if those ports are taken |
| `CONTACT_EMAIL` | Bridge contact e-mail | Not public as it is for a relay: only people with the fingerprint can see it |
| `BRIDGE_NICKNAME` | Bridge name | **Only [a-zA-Z0-9], 1 to 19 characters**; otherwise the bridge does not start |
| `TELEGRAM_BOT_TOKEN` | Bot token (from @BotFather) | Regenerate it if it was ever exposed |
| `TELEGRAM_CHAT_ID` | Your chat ID | Get it from `api.telegram.org/bot<TOKEN>/getUpdates` after sending `/start` to the bot |
| `BRIDGE_FINGERPRINT` | Hash of the bridge identity | Leave it empty: the script fills it in after the first start |
| `CRON_SCHEDULE` | Time of the daily summary | **Must be quoted**, e.g. `"0 9 * * *"`; without quotes the script breaks |

## If the fingerprint is not captured automatically

```bash
cd /opt/tor-bridge-stack
docker compose logs tor-bridge | grep -i "hashed identity"
# paste the value into BRIDGE_FINGERPRINT in the .env, then:
docker compose up -d --build daily-summary
```

## What stays manual

**Uptime Kuma** cannot be configured from a file, only from its web interface:

1. SSH tunnel: `ssh -L 3001:localhost:3001 root@<vps-ip>`
2. Open `http://localhost:3001` and create the admin account.
3. **Settings → Notifications** → add Telegram (same token and chat ID as in the `.env`).
4. **Add New Monitor** → type `TCP Port` → port = the value of `OR_PORT` → select the notification you created.

## Known errors

- `.env: line X: 9: command not found` → `CRON_SCHEDULE` is missing quotes. Change it to `CRON_SCHEDULE="0 9 * * *"`.
- The bridge does not start, or a "Nickname" error → `BRIDGE_NICKNAME` has an invalid character (hyphen, underscore, space, accent) or more than 19 characters.

## License

[MIT](LICENSE)
