#
# SPDX-License-Identifier: GPL-3.0-or-later
#

import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "imageroot", "pypkg"))
import bridge_setup  # noqa: E402

VALID = {
    "matrix_homeserver_url": "https://matrix.example.org/",
    "matrix_access_token": "syt_dm9pY2Vib3Q_abcdef",
    "matrix_allowed_user": "@me:example.org",
    "discord_bot_token": "MTIzNDU2.Gabcde.xyz-_123",
    "discord_guild_id": "123456789012345678",
    "discord_voice_channel_id": "234567890123456789",
}


class BridgeSetupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def apply(self, request):
        return bridge_setup.apply_request(request, self.dir)

    def error(self, request):
        with self.assertRaises(bridge_setup.SettingsError) as ctx:
            self.apply(request)
        return ctx.exception

    def mode(self, name):
        return stat.S_IMODE(os.stat(os.path.join(self.dir, name)).st_mode)

    def test_first_configuration_needs_all_required_settings(self):
        error = self.error({k: v for k, v in VALID.items() if k != "discord_bot_token"})
        self.assertEqual((error.field, error.error), ("discord_bot_token", "required"))
        self.assertFalse(os.path.exists(os.path.join(self.dir, bridge_setup.SETTINGS_FILE)))
        error = self.error({})
        self.assertEqual(error.error, "required")

    def test_valid_settings_are_stored_privately(self):
        settings = self.apply(VALID)
        self.assertEqual(settings["matrix_homeserver_url"], "https://matrix.example.org")
        self.assertEqual(settings["matrix_room_name"], "Discord voice")
        self.assertTrue(settings["use_homeserver_turn"])
        self.assertEqual(self.mode(bridge_setup.SETTINGS_FILE), 0o600)
        with open(os.path.join(self.dir, bridge_setup.SETTINGS_FILE)) as stream:
            self.assertEqual(json.load(stream)["discord_bot_token"], VALID["discord_bot_token"])

    def test_empty_request_and_empty_tokens_keep_settings(self):
        self.apply(VALID)
        settings = self.apply({})
        self.assertEqual(settings["matrix_access_token"], VALID["matrix_access_token"])
        settings = self.apply({"matrix_access_token": "", "discord_bot_token": "  ", "public_ip": "203.0.113.5"})
        self.assertEqual(settings["matrix_access_token"], VALID["matrix_access_token"])
        self.assertEqual(settings["discord_bot_token"], VALID["discord_bot_token"])
        self.assertEqual(settings["public_ip"], "203.0.113.5")
        settings = self.apply({"matrix_access_token": "syt_new"})
        self.assertEqual(settings["matrix_access_token"], "syt_new")

    def test_invalid_values_are_rejected_and_not_stored(self):
        self.apply(VALID)
        cases = [
            ({"matrix_homeserver_url": "matrix.example.org"}, "invalid_homeserver_url"),
            ({"matrix_homeserver_url": "https://a b"}, "invalid_homeserver_url"),
            ({"matrix_allowed_user": "me"}, "invalid_matrix_user"),
            ({"matrix_allowed_user": "@Me:example.org"}, "invalid_matrix_user"),
            ({"discord_guild_id": "12345"}, "invalid_discord_id"),
            ({"discord_voice_channel_id": "abc"}, "invalid_discord_id"),
            ({"discord_bot_token": "two words"}, "invalid_token"),
            ({"matrix_access_token": "line\nbreak"}, "invalid_token"),
            ({"matrix_room_name": "a\nb"}, "invalid_room_name"),
            ({"matrix_room_name": "x" * 101}, "invalid_room_name"),
            ({"public_ip": "999.1.1.1"}, "invalid_ip_address"),
            ({"use_homeserver_turn": "yes"}, "invalid_boolean"),
        ]
        for request, code in cases:
            with self.subTest(request=request):
                self.assertEqual(self.error(request).error, code)
        self.assertEqual(bridge_setup.read_settings(self.dir)["matrix_allowed_user"], VALID["matrix_allowed_user"])

    def test_invalid_token_is_not_echoed(self):
        self.apply(VALID)
        error = self.error({"discord_bot_token": "secret with space"})
        self.assertEqual(error.value, "")
        self.assertNotIn("secret", str(error))

    def test_ipv6_is_normalized(self):
        settings = self.apply({**VALID, "public_ip": "2001:DB8:0::1"})
        self.assertEqual(settings["public_ip"], "2001:db8::1")

    def test_env_file_is_private_and_restart_flag_only_on_change(self):
        settings = self.apply(VALID)
        flag = os.path.join(self.dir, bridge_setup.RESTART_FLAG)
        self.assertTrue(bridge_setup.write_env(settings, self.dir))
        self.assertTrue(os.path.exists(flag))
        self.assertEqual(self.mode(bridge_setup.ENV_FILE), 0o600)
        with open(os.path.join(self.dir, bridge_setup.ENV_FILE)) as stream:
            env = dict(line.rstrip("\n").split("=", 1) for line in stream)
        self.assertEqual(env["MATRIX_HOMESERVER_URL"], "https://matrix.example.org")
        self.assertEqual(env["DISCORD_BOT_TOKEN"], VALID["discord_bot_token"])
        self.assertEqual(env["WEBRTC_PUBLIC_IP"], "")
        self.assertEqual(env["USE_HOMESERVER_TURN"], "true")
        os.remove(flag)
        self.assertFalse(bridge_setup.write_env(settings, self.dir))
        self.assertFalse(os.path.exists(flag))
        settings = self.apply({"use_homeserver_turn": False})
        self.assertTrue(bridge_setup.write_env(settings, self.dir))
        self.assertTrue(os.path.exists(flag))

    def test_configuration_hides_tokens(self):
        self.assertFalse(bridge_setup.configuration(bridge_setup.read_settings(self.dir))["configured"])
        output = bridge_setup.configuration(self.apply(VALID), "20004-20011")
        self.assertNotIn("matrix_access_token", output)
        self.assertNotIn("discord_bot_token", output)
        self.assertNotIn(VALID["discord_bot_token"], json.dumps(output))
        self.assertTrue(output["matrix_access_token_set"])
        self.assertTrue(output["discord_bot_token_set"])
        self.assertTrue(output["configured"])
        self.assertEqual(output["udp_ports"], "20004-20011")
        self.assertEqual(bridge_setup.configuration(bridge_setup.read_settings(self.dir), "")["udp_ports"], "")

    def test_firewall_opens_the_whole_range(self):
        self.assertEqual(bridge_setup.firewall_ports({"UDP_PORTS_RANGE": "20004-20011"}), ["20004-20011/udp"])


if __name__ == "__main__":
    unittest.main()
