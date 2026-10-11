*** Settings ***
Library    SSHLibrary
Library    String

*** Variables ***
${IMAGE_URL}         ghcr.io/platypuschan/matrix-discord-bridge:latest
# The update scenario starts from the last published release of this module;
# test-module-update.sh looks it up in the registry.
${PREVIOUS_IMAGE_URL}    ${EMPTY}
${SCENARIO}          install
${module_id}         ${EMPTY}
${udp_ports}         ${EMPTY}
# A stand-in homeserver on the node (tests/fake_homeserver.py); the bridge
# container reaches the node as host.containers.internal.
${FAKE_HS_PORT}      18008
${FAKE_HS_LOG}       /root/fake-homeserver.log
${HS_URL}            http://host.containers.internal:18008
${MATRIX_TOKEN}      syt_ci_matrix_token
${DISCORD_TOKEN}     ci.discord.token
${GUILD_ID}          123456789012345678
${CHANNEL_ID}        234567890123456789
${ADMIN_USER}        admin
${ADMIN_PASSWORD}    Nethesis,1234

*** Keywords ***
Login to cluster-admin
    New Page    https://${NODE_ADDR}/cluster-admin/
    Fill Text    text="Username"    ${ADMIN_USER}
    Click    button >> text="Continue"
    Fill Text    text="Password"    ${ADMIN_PASSWORD}
    Click    button >> text="Log in"
    Wait For Elements State    css=#main-content    visible    timeout=10s

Get configuration
    ${output}    ${rc} =    Execute Command    api-cli run module/${module_id}/get-configuration
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0    get-configuration failed: ${output}
    &{config} =    Evaluate    json.loads(r'''${output}''')    modules=json
    RETURN    &{config}

Run action
    [Arguments]    ${action}    ${payload}
    ${output}    ${rc} =    Execute Command    api-cli run module/${module_id}/${action} --data '${payload}'
    ...    return_rc=True
    RETURN    ${output}    ${rc}

Configure current module
    [Arguments]    &{settings}
    ${payload} =    Evaluate    json.dumps($settings)    modules=json
    ${output}    ${rc} =    Run action    configure-module    ${payload}
    Should Be Equal As Integers    ${rc}    0    configure-module failed: ${output}

Configure with test settings
    Configure current module
    ...    matrix_homeserver_url=${HS_URL}
    ...    matrix_access_token=${MATRIX_TOKEN}
    ...    matrix_allowed_user=@ci:example.org
    ...    discord_bot_token=${DISCORD_TOKEN}
    ...    discord_guild_id=${GUILD_ID}
    ...    discord_voice_channel_id=${CHANNEL_ID}

Configuration is rejected
    [Arguments]    ${payload}    ${error}
    ${output}    ${rc} =    Run action    configure-module    ${payload}
    Should Not Be Equal As Integers    ${rc}    0
    Should Contain    ${output}    ${error}

Fake homeserver saw the bridge
    ${log} =    Execute Command    cat ${FAKE_HS_LOG}
    Should Contain    ${log}    GET /_matrix/client/v3/account/whoami Bearer ${MATRIX_TOKEN}

Wait until the bridge calls the homeserver
    # The bridge logs in to Matrix first; with the fake Discord token it then
    # exits and systemd retries every 30 seconds.
    Execute Command    rm -f ${FAKE_HS_LOG}
    Wait Until Keyword Succeeds    120 seconds    3 seconds    Fake homeserver saw the bridge

Read allocated UDP ports
    ${ports} =    Execute Command    runagent -m ${module_id} printenv UDP_PORTS_RANGE
    ${ports} =    Strip String    ${ports}
    Should Match Regexp    ${ports}    ^[0-9]+-[0-9]+$
    ${first}    ${last} =    Split String    ${ports}    -
    Should Be Equal As Integers    ${{int($last) - int($first)}}    7    expected 8 UDP ports
    Set Suite Variable    ${udp_ports}    ${ports}

*** Test Cases ***
Start the fake homeserver
    Put File    ${CURDIR}/fake_homeserver.py    /root/fake_homeserver.py
    Execute Command    systemctl stop fake-homeserver.service; systemctl reset-failed fake-homeserver.service
    ${output}    ${rc} =    Execute Command    systemd-run --unit fake-homeserver python3 /root/fake_homeserver.py ${FAKE_HS_PORT} ${FAKE_HS_LOG}
    ...    return_rc=True    return_stderr=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0    starting the fake homeserver failed: ${output}
    Wait Until Keyword Succeeds    20 seconds    1 second
    ...    Execute Command    curl -fsS http://127.0.0.1:${FAKE_HS_PORT}/_matrix/client/v3/account/whoami

Add module for ${SCENARIO} scenario
    IF    r'${SCENARIO}' == 'update'
        Set Local Variable    ${install_image}    ${PREVIOUS_IMAGE_URL}
    ELSE
        Set Local Variable    ${install_image}    ${IMAGE_URL}
    END
    ${output}    ${rc} =    Execute Command    add-module ${install_image} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0    add-module ${install_image} failed: ${output}
    &{output} =    Evaluate    ast.literal_eval(r'''${output}''')    modules=ast
    Set Suite Variable    ${module_id}    ${output.module_id}

UDP ports are allocated and open in the firewall
    Read allocated UDP ports
    ${service} =    Execute Command    firewall-cmd --info-service=${module_id}
    Should Contain    ${service}    ${udp_ports}/udp
    ${services} =    Execute Command    firewall-cmd --zone=public --list-services
    Should Contain    ${services}    ${module_id}

A new module is not configured and does not run
    Skip If    r'${SCENARIO}' == 'update'    the previous release is configured below
    &{config} =    Get configuration
    Should Be Equal    ${config.configured}    ${False}
    Should Be Equal    ${config.udp_ports}    ${udp_ports}
    ${rc} =    Execute Command    runagent -m ${module_id} systemctl --user is-active --quiet bridge.service
    ...    return_rc=True    return_stdout=False
    Should Not Be Equal As Integers    ${rc}    0

Incomplete settings are rejected
    Configuration is rejected    {}    required
    Configuration is rejected    {"matrix_homeserver_url": "${HS_URL}"}    required

Configure initial module
    Configure with test settings
    Wait until the bridge calls the homeserver

Update module from the previous release
    Skip If    r'${SCENARIO}' != 'update'    only the update scenario updates the module
    Log    Scenario ${SCENARIO} with ${IMAGE_URL}    console=${True}
    # Same request as the Software Center: no forced pull.
    ${output}    ${rc} =    Execute Command    api-cli run update-module --data '{"module_url":"${IMAGE_URL}","instances":["${module_id}"]}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}    0    update-module ${IMAGE_URL} failed: ${output}
    ${journal} =    Execute Command    journalctl -q --no-pager SYSLOG_IDENTIFIER=agent@${module_id}
    Should Not Contain    ${journal}    has failed    an update-module.d step failed
    ${image} =    Execute Command    runagent -m ${module_id} printenv IMAGE_URL
    ${image} =    Strip String    ${image}
    Should Be Equal    ${image}    ${IMAGE_URL}
    # The settings survive the update and the updated bridge uses them
    &{config} =    Get configuration
    Should Be Equal    ${config.configured}    ${True}
    Wait until the bridge calls the homeserver

The bridge runs from the pinned image
    ${image} =    Execute Command    runagent -m ${module_id} printenv DISCORD_MATRIX_VOICE_IMAGE
    ${image} =    Strip String    ${image}
    Should Match Regexp    ${image}    ^ghcr\\.io/platypuschan/discord-matrix-voice:[0-9a-f]{12}$
    ${rc} =    Execute Command    runagent -m ${module_id} podman image exists ${image}
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    ${enabled} =    Execute Command    runagent -m ${module_id} systemctl --user is-enabled bridge.service
    Should Be Equal    ${enabled}    enabled

The UDP ports are passed to the bridge
    ${unit} =    Execute Command    runagent -m ${module_id} systemctl --user cat bridge.service
    Should Contain    ${unit}    --publish \${UDP_PORTS_RANGE}:\${UDP_PORTS_RANGE}/udp
    Should Contain    ${unit}    WEBRTC_PORT_RANGE=\${UDP_PORTS_RANGE}

get-configuration hides the tokens
    &{config} =    Get configuration
    ${output} =    Execute Command    api-cli run module/${module_id}/get-configuration
    Should Not Contain    ${output}    ${MATRIX_TOKEN}
    Should Not Contain    ${output}    ${DISCORD_TOKEN}
    Should Be Equal    ${config.configured}    ${True}
    Should Be Equal    ${config.matrix_access_token_set}    ${True}
    Should Be Equal    ${config.discord_bot_token_set}    ${True}
    Should Be Equal    ${config.matrix_homeserver_url}    ${HS_URL}
    Should Be Equal    ${config.discord_guild_id}    ${GUILD_ID}
    Should Be Equal    ${config.udp_ports}    ${udp_ports}

Settings and tokens are private
    ${modes} =    Execute Command    runagent -m ${module_id} stat -c '%a' bridge.json bridge.env
    Should Be Equal    ${modes}    600\n600
    ${environment} =    Execute Command    runagent -m ${module_id} cat environment
    Should Not Contain    ${environment}    ${MATRIX_TOKEN}
    Should Not Contain    ${environment}    ${DISCORD_TOKEN}

Invalid settings are rejected and change nothing
    Configuration is rejected    {"matrix_homeserver_url": "matrix.example.org"}    invalid_homeserver_url
    Configuration is rejected    {"matrix_allowed_user": "ci"}    invalid_matrix_user
    Configuration is rejected    {"discord_guild_id": "123"}    invalid_discord_id
    Configuration is rejected    {"discord_bot_token": "two words"}    invalid_token
    Configuration is rejected    {"public_ip": "not-an-ip"}    invalid_ip_address
    &{config} =    Get configuration
    Should Be Equal    ${config.matrix_allowed_user}    @ci:example.org
    Should Be Equal    ${config.discord_guild_id}    ${GUILD_ID}
    ${output} =    Execute Command    api-cli run module/${module_id}/configure-module --data '{"discord_bot_token": "secret with space"}'
    Should Not Contain    ${output}    secret with space

Saving unchanged settings keeps the bridge running
    ${before} =    Execute Command    runagent -m ${module_id} stat -c %Y bridge.env
    Configure current module
    ${after} =    Execute Command    runagent -m ${module_id} stat -c %Y bridge.env
    Should Be Equal    ${after}    ${before}    bridge.env was rewritten although nothing changed
    ${rc} =    Execute Command    runagent -m ${module_id} test ! -e bridge-restart-needed
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0

Omitted and empty tokens are kept
    Configure current module    matrix_access_token=${EMPTY}    discord_bot_token=${EMPTY}    public_ip=203.0.113.10
    ${env} =    Execute Command    runagent -m ${module_id} cat bridge.env
    Should Contain    ${env}    MATRIX_ACCESS_TOKEN=${MATRIX_TOKEN}\n
    Should Contain    ${env}    DISCORD_BOT_TOKEN=${DISCORD_TOKEN}\n
    Should Contain    ${env}    WEBRTC_PUBLIC_IP=203.0.113.10\n
    # A changed setting restarts the bridge with it
    Wait until the bridge calls the homeserver

Backup includes the settings
    ${include} =    Execute Command    runagent -m ${module_id} sh -c 'cat ../etc/state-include.conf'
    Should Match Regexp    ${include}    (?m)^state/bridge.json$

Module UI loads in cluster-admin
    [Tags]    ui
    Import Library    Browser
    New Browser    chromium    headless=True
    New Context    ignoreHTTPSErrors=True
    Login to cluster-admin
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}
    Wait For Elements State    iframe >>> h2 >> text="Status"    visible    timeout=20s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/1._Status.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=settings
    Wait For Elements State    iframe >>> h2 >> text="Settings"    visible    timeout=20s
    # The fields are only enabled and filled after get-configuration
    Wait For Elements State    iframe >>> input#matrix-homeserver-url    enabled    timeout=30s
    Get Property    iframe >>> input#matrix-homeserver-url    value    ==    ${HS_URL}
    Get Property    iframe >>> input#matrix-allowed-user    value    ==    @ci:example.org
    Get Property    iframe >>> input#discord-voice-channel-id    value    ==    ${CHANNEL_ID}
    Get Property    iframe >>> input#public-ip    value    ==    203.0.113.10
    # Saved tokens are never sent to the browser
    Get Property    iframe >>> input#matrix-access-token    type    ==    password
    Get Property    iframe >>> input#matrix-access-token    value    ==    ${EMPTY}
    Get Property    iframe >>> input#discord-bot-token    value    ==    ${EMPTY}
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/2._Settings.png
    Close Browser

Remove module
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True    return_stdout=False
    Should Be Equal As Integers    ${rc}    0
    ${services} =    Execute Command    firewall-cmd --zone=public --list-services
    Should Not Contain    ${services}    ${module_id}

Stop the fake homeserver
    Execute Command    systemctl stop fake-homeserver.service
