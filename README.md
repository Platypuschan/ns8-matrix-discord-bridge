# ns8-matrix-discord-bridge

NethServer 8 module for
[discord-matrix-voice](https://github.com/Platypuschan/discord-matrix-voice),
a personal bridge from a [Matrix](https://matrix.org/) voice call to a
Discord voice channel.

You call the bot from Element Web or Element Desktop. The bot joins the
configured Discord voice channel and bridges the audio both ways; hanging up
makes it leave. Only calls from one Matrix user are accepted. See the
[bridge README](https://github.com/Platypuschan/discord-matrix-voice#readme)
for how it works and its limits (Element X is not supported; the call room
is unencrypted, the call audio itself is encrypted).

The module runs the bridge as a rootless container from
`ghcr.io/platypuschan/discord-matrix-voice:<commit>`, pinned in
`build-images.sh`. It adds:

- a **Settings** page for the Matrix and Discord settings; saved tokens are
  never shown again or returned by the API;
- a range of 8 UDP ports for the call audio, allocated by NS8 and opened in
  the node firewall;
- NS8 backup and restore of the settings. The bridge keeps no other data.

## Install

Install a fixed version, so that the Software Center offers later updates:

```
add-module ghcr.io/platypuschan/matrix-discord-bridge:0.1.0 1
```

The output of the command returns the instance name, for example
`matrix-discord-bridge1`.

## Prepare the accounts

1. **Matrix:** register a separate account for the bot, for example
   `@voicebot:example.org`, and get an access token:

   ```
   curl -s -X POST https://matrix.example.org/_matrix/client/v3/login \
     -H 'Content-Type: application/json' \
     -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"voicebot"},"password":"…","initial_device_display_name":"discord-matrix-voice"}'
   ```

2. **Discord:** create an application at
   <https://discord.com/developers/applications>, copy the bot token and
   invite the bot with View Channel, Connect and Speak permissions:
   `https://discord.com/oauth2/authorize?client_id=APP_ID&scope=bot&permissions=3146752`.
   With Developer Mode enabled in Discord, copy the server ID and the voice
   channel ID.

## Configure

Open the module in cluster-admin and fill in the **Settings** page. The
bridge starts as soon as all required settings are saved and invites the
allowed user to an unencrypted room named "Discord voice"; call the bot from
there.

The same configuration from the command line:

```
api-cli run module/matrix-discord-bridge1/configure-module --data '{
  "matrix_homeserver_url": "https://matrix.example.org",
  "matrix_access_token": "syt_…",
  "matrix_allowed_user": "@me:example.org",
  "discord_bot_token": "MTIz…",
  "discord_guild_id": "123456789012345678",
  "discord_voice_channel_id": "234567890123456789"
}'
api-cli run module/matrix-discord-bridge1/get-configuration
```

Optional fields (omitted fields keep their value; omitted or empty tokens
keep the saved token):

- `matrix_room_name`: name of the room the bot creates (default
  `Discord voice`);
- `public_ip`: public IP address of the node to advertise for the call
  audio, see [Call audio](#call-audio);
- `use_homeserver_turn`: use the TURN server of the bot's homeserver
  (default `true`).

`get-configuration` returns `matrix_access_token_set` and
`discord_bot_token_set` instead of the tokens, `configured` (all required
settings are set) and `udp_ports`.

## Call audio

The audio between your Matrix client and the bridge goes over WebRTC (UDP).
The bridge opens its WebRTC sockets only in the module's UDP port range
(`udp_ports` in `get-configuration`, also shown on the Settings page), which
the module opens in the node firewall. A call uses one port per network
address of the node plus one for TURN, hence a range of 8. Your client
reaches the bridge in one of these ways:

- **Homeserver TURN** (default): if the homeserver has a TURN server
  (Synapse `turn_uris`), the bridge relays through it, like Element does.
- **Direct:** the node is reachable on its own address, or the UDP range is
  forwarded to it and `public_ip` is set to the public address.

## Uninstall

```
remove-module --no-preserve matrix-discord-bridge1
```

The firewall ports are closed when the module is removed.

## Tests

`test-module.sh <node address> <image URL> <install|update>` runs the Robot
Framework suite in `tests/` against an NS8 node. CI runs it on QEMU for
Rocky Linux 9 and Debian 13. A stand-in homeserver on the node
(`tests/fake_homeserver.py`) checks that the bridge starts with the
configured settings; no real Matrix or Discord accounts are needed.
