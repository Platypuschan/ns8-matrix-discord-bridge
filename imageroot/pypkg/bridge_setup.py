#
# SPDX-License-Identifier: GPL-3.0-or-later
#

"""Settings of the Matrix-Discord voice bridge.

The settings are stored in state/bridge.json (mode 600, part of the backup).
configure-module renders them into state/bridge.env, the environment file of
the bridge container (mode 600). The tokens never go to the module
environment, which other agents of the cluster can read, and are never
returned by get-configuration.
"""

import contextlib
import fcntl
import ipaddress
import json
import os
import re
import tempfile

SETTINGS_FILE = "bridge.json"
ENV_FILE = "bridge.env"
LOCK_FILE = ".bridge.lock"
# Left by write_env() when bridge.env changed; 80start_services restarts the
# bridge and removes it.
RESTART_FLAG = "bridge-restart-needed"

# Settings and their defaults. Tokens are secrets: requests may omit them or
# send "" to keep the stored value.
DEFAULTS = {
    "matrix_homeserver_url": "",
    "matrix_access_token": "",
    "matrix_allowed_user": "",
    "matrix_room_name": "Discord voice",
    "discord_bot_token": "",
    "discord_guild_id": "",
    "discord_voice_channel_id": "",
    "public_ip": "",
    "use_homeserver_turn": True,
}
SECRETS = ("matrix_access_token", "discord_bot_token")
REQUIRED = (
    "matrix_homeserver_url",
    "matrix_access_token",
    "matrix_allowed_user",
    "discord_bot_token",
    "discord_guild_id",
    "discord_voice_channel_id",
)

HOMESERVER_URL = re.compile(r"^https?://[^\s/?#]+(/[^\s?#]*)?$")
MATRIX_USER = re.compile(r"^@[a-z0-9._=\-/+]+:[^\s:]+(:[0-9]{1,5})?$")
# Discord IDs are snowflakes: 17-20 digit integers.
SNOWFLAKE = re.compile(r"^[0-9]{17,20}$")
TOKEN = re.compile(r"^[\x21-\x7e]{1,4096}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
PORT_RANGE = re.compile(r"^[0-9]{1,5}-[0-9]{1,5}$")


class SettingsError(Exception):
    def __init__(self, field, error, value=""):
        super().__init__(f"{field}: {error}")
        self.field = field
        self.error = error
        self.value = value


def _path(state_dir, name):
    return os.path.join(state_dir, name)


@contextlib.contextmanager
def settings_lock(state_dir="."):
    """Serialize configure-module and update-module.d runs."""
    with open(_path(state_dir, LOCK_FILE), "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def _write_private(path, text):
    """Atomically write text to path with mode 600."""
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def read_settings(state_dir="."):
    settings = dict(DEFAULTS)
    try:
        with open(_path(state_dir, SETTINGS_FILE), encoding="utf-8") as stream:
            stored = json.load(stream)
    except FileNotFoundError:
        return settings
    for key in DEFAULTS:
        if key in stored:
            settings[key] = stored[key]
    return settings


def save_settings(settings, state_dir="."):
    _write_private(_path(state_dir, SETTINGS_FILE), json.dumps(settings, indent=2, sort_keys=True) + "\n")


def is_complete(settings):
    return all(settings.get(key) for key in REQUIRED)


def _validate(settings):
    url = settings["matrix_homeserver_url"]
    if url and not HOMESERVER_URL.match(url):
        raise SettingsError("matrix_homeserver_url", "invalid_homeserver_url", url)
    user = settings["matrix_allowed_user"]
    if user and not MATRIX_USER.match(user):
        raise SettingsError("matrix_allowed_user", "invalid_matrix_user", user)
    for key in ("discord_guild_id", "discord_voice_channel_id"):
        if settings[key] and not SNOWFLAKE.match(settings[key]):
            raise SettingsError(key, "invalid_discord_id", settings[key])
    for key in SECRETS:
        if settings[key] and not TOKEN.match(settings[key]):
            # Never echo a token back, not even an invalid one.
            raise SettingsError(key, "invalid_token")
    name = settings["matrix_room_name"]
    if not name or len(name) > 100 or CONTROL.search(name):
        raise SettingsError("matrix_room_name", "invalid_room_name", name)
    address = settings["public_ip"]
    if address:
        try:
            parsed = ipaddress.ip_address(address)
        except ValueError:
            raise SettingsError("public_ip", "invalid_ip_address", address) from None
        settings["public_ip"] = str(parsed)
    if not isinstance(settings["use_homeserver_turn"], bool):
        raise SettingsError("use_homeserver_turn", "invalid_boolean", str(settings["use_homeserver_turn"]))


def apply_request(request, state_dir="."):
    """Merge a configure-module request into the stored settings.

    Omitted fields keep their value; omitted or empty tokens keep the stored
    token, so clone and restore can send an empty request. Raises
    SettingsError for invalid values or when a required setting is still
    missing afterwards. Returns the new settings.
    """
    settings = read_settings(state_dir)
    for key in DEFAULTS:
        if key not in request:
            continue
        value = request[key]
        if isinstance(value, str):
            value = value.strip()
        if key in SECRETS and value == "":
            continue
        settings[key] = value
    if settings["matrix_homeserver_url"]:
        settings["matrix_homeserver_url"] = settings["matrix_homeserver_url"].rstrip("/")
    _validate(settings)
    if not is_complete(settings):
        missing = next(key for key in REQUIRED if not settings.get(key))
        raise SettingsError(missing, "required")
    save_settings(settings, state_dir)
    return settings


def render_env(settings):
    """bridge.env content for podman --env-file (one KEY=value per line)."""
    lines = {
        "MATRIX_HOMESERVER_URL": settings["matrix_homeserver_url"],
        "MATRIX_ACCESS_TOKEN": settings["matrix_access_token"],
        "MATRIX_ALLOWED_USER": settings["matrix_allowed_user"],
        "MATRIX_ROOM_NAME": settings["matrix_room_name"],
        "DISCORD_BOT_TOKEN": settings["discord_bot_token"],
        "DISCORD_GUILD_ID": settings["discord_guild_id"],
        "DISCORD_VOICE_CHANNEL_ID": settings["discord_voice_channel_id"],
        "WEBRTC_PUBLIC_IP": settings["public_ip"],
        "USE_HOMESERVER_TURN": "true" if settings["use_homeserver_turn"] else "false",
    }
    for key, value in lines.items():
        # Validation keeps newlines out; this guards against future fields.
        if CONTROL.search(value):
            raise SettingsError(key.lower(), "invalid_value")
    return "".join(f"{key}={value}\n" for key, value in lines.items())


def write_env(settings, state_dir="."):
    """Render bridge.env; flag a restart only when its content changed."""
    path = _path(state_dir, ENV_FILE)
    text = render_env(settings)
    try:
        with open(path, encoding="utf-8") as stream:
            if stream.read() == text:
                return False
    except FileNotFoundError:
        pass
    _write_private(path, text)
    with open(_path(state_dir, RESTART_FLAG), "w"):
        pass
    return True


def configuration(settings, udp_ports=""):
    """get-configuration output: everything except the tokens."""
    output = {key: value for key, value in settings.items() if key not in SECRETS}
    for key in SECRETS:
        output[key + "_set"] = bool(settings.get(key))
    output["configured"] = is_complete(settings)
    output["udp_ports"] = udp_ports if PORT_RANGE.match(udp_ports or "") else ""
    return output


def firewall_ports(environ):
    """Ports to open: the module's UDP range (UDP_PORTS_RANGE, "a-b").

    The bridge's WebRTC stack (werift) opens one socket per local address
    plus one for TURN, each on the first free port of the range, so a call
    needs several ports; see org.nethserver.udp-ports-demand.
    """
    return [environ["UDP_PORTS_RANGE"] + "/udp"]
