<!--
  Copyright (C) 2022 Nethesis S.r.l.
  SPDX-License-Identifier: GPL-3.0-or-later
-->
<template>
  <cv-grid fullWidth>
    <cv-row>
      <cv-column class="page-title">
        <h2>{{ $t("settings.title") }}</h2>
      </cv-column>
    </cv-row>
    <cv-row v-if="error.getConfiguration">
      <cv-column>
        <NsInlineNotification
          kind="error"
          :title="$t('action.get-configuration')"
          :description="error.getConfiguration"
          :showCloseButton="false"
        />
      </cv-column>
    </cv-row>
    <cv-row v-if="!loading.getConfiguration && !configured">
      <cv-column>
        <NsInlineNotification
          kind="info"
          :title="$t('settings.not_configured')"
          :description="$t('settings.not_configured_description')"
          :showCloseButton="false"
        />
      </cv-column>
    </cv-row>
    <cv-row>
      <cv-column>
        <cv-tile light>
          <h4 class="mg-bottom-sm">{{ $t("settings.how_title") }}</h4>
          <p class="helper">{{ $t("settings.how_description") }}</p>
        </cv-tile>
      </cv-column>
    </cv-row>
    <cv-row>
      <cv-column>
        <cv-tile light>
          <cv-form @submit.prevent="configureModule">
            <!-- Matrix -->
            <h4 class="mg-bottom-sm">{{ $t("settings.matrix_title") }}</h4>
            <p class="mg-bottom helper">
              {{ $t("settings.matrix_description") }}
            </p>
            <cv-text-input
              id="matrix-homeserver-url"
              :label="$t('settings.homeserver_url')"
              placeholder="https://matrix.example.org"
              v-model.trim="matrixHomeserverUrl"
              :invalid-message="$t(error.matrix_homeserver_url)"
              :disabled="busy"
              class="mg-bottom"
              ref="matrix_homeserver_url"
            />
            <cv-text-input
              id="matrix-access-token"
              :label="$t('settings.access_token')"
              :helper-text="
                matrixAccessTokenSet ? $t('settings.token_set_helper') : ''
              "
              v-model.trim="matrixAccessToken"
              type="password"
              autocomplete="new-password"
              :invalid-message="$t(error.matrix_access_token)"
              :disabled="busy"
              class="mg-bottom"
              ref="matrix_access_token"
            />
            <cv-text-input
              id="matrix-allowed-user"
              :label="$t('settings.allowed_user')"
              :helper-text="$t('settings.allowed_user_helper')"
              placeholder="@me:example.org"
              v-model.trim="matrixAllowedUser"
              :invalid-message="$t(error.matrix_allowed_user)"
              :disabled="busy"
              class="mg-bottom"
              ref="matrix_allowed_user"
            />
            <cv-text-input
              id="matrix-room-name"
              :label="$t('settings.room_name')"
              :helper-text="$t('settings.room_name_helper')"
              v-model.trim="matrixRoomName"
              :invalid-message="$t(error.matrix_room_name)"
              :disabled="busy"
              class="mg-bottom-lg"
              ref="matrix_room_name"
            />
            <!-- Discord -->
            <h4 class="mg-bottom-sm">{{ $t("settings.discord_title") }}</h4>
            <p class="mg-bottom helper">
              {{ $t("settings.discord_description") }}
            </p>
            <cv-text-input
              id="discord-bot-token"
              :label="$t('settings.bot_token')"
              :helper-text="
                discordBotTokenSet ? $t('settings.token_set_helper') : ''
              "
              v-model.trim="discordBotToken"
              type="password"
              autocomplete="new-password"
              :invalid-message="$t(error.discord_bot_token)"
              :disabled="busy"
              class="mg-bottom"
              ref="discord_bot_token"
            />
            <cv-text-input
              id="discord-guild-id"
              :label="$t('settings.guild_id')"
              placeholder="123456789012345678"
              v-model.trim="discordGuildId"
              :invalid-message="$t(error.discord_guild_id)"
              :disabled="busy"
              class="mg-bottom"
              ref="discord_guild_id"
            />
            <cv-text-input
              id="discord-voice-channel-id"
              :label="$t('settings.channel_id')"
              placeholder="234567890123456789"
              v-model.trim="discordVoiceChannelId"
              :invalid-message="$t(error.discord_voice_channel_id)"
              :disabled="busy"
              class="mg-bottom-lg"
              ref="discord_voice_channel_id"
            />
            <!-- call media -->
            <h4 class="mg-bottom-sm">{{ $t("settings.network_title") }}</h4>
            <p class="mg-bottom helper">
              {{ $t("settings.network_description", { ports: udpPorts }) }}
            </p>
            <cv-text-input
              id="public-ip"
              :label="$t('settings.public_ip')"
              :helper-text="$t('settings.public_ip_helper')"
              placeholder="203.0.113.10"
              v-model.trim="publicIp"
              :invalid-message="$t(error.public_ip)"
              :disabled="busy"
              class="mg-bottom"
              ref="public_ip"
            />
            <cv-toggle
              value="useHomeserverTurn"
              :label="$t('settings.homeserver_turn')"
              v-model="useHomeserverTurn"
              :disabled="busy"
              class="mg-bottom"
            >
              <template slot="text-left">{{
                $t("settings.disabled")
              }}</template>
              <template slot="text-right">{{
                $t("settings.enabled")
              }}</template>
            </cv-toggle>
            <cv-row v-if="error.configureModule">
              <cv-column>
                <NsInlineNotification
                  kind="error"
                  :title="$t('action.configure-module')"
                  :description="error.configureModule"
                  :showCloseButton="false"
                />
              </cv-column>
            </cv-row>
            <NsButton
              kind="primary"
              :icon="Save20"
              :loading="loading.configureModule"
              :disabled="busy"
              >{{ $t("settings.save") }}</NsButton
            >
          </cv-form>
        </cv-tile>
      </cv-column>
    </cv-row>
  </cv-grid>
</template>

<script>
import to from "await-to-js";
import { mapState } from "vuex";
import {
  QueryParamService,
  UtilService,
  TaskService,
  IconService,
  PageTitleService,
} from "@nethserver/ns8-ui-lib";

// Field order: the first invalid field gets the focus.
const FIELDS = [
  "matrix_homeserver_url",
  "matrix_access_token",
  "matrix_allowed_user",
  "matrix_room_name",
  "discord_bot_token",
  "discord_guild_id",
  "discord_voice_channel_id",
  "public_ip",
];

export default {
  name: "Settings",
  mixins: [
    TaskService,
    IconService,
    UtilService,
    QueryParamService,
    PageTitleService,
  ],
  pageTitle() {
    return this.$t("settings.title") + " - " + this.appName;
  },
  data() {
    return {
      q: {
        page: "settings",
      },
      urlCheckInterval: null,
      configured: true,
      udpPorts: "",
      matrixHomeserverUrl: "",
      matrixAccessToken: "",
      matrixAccessTokenSet: false,
      matrixAllowedUser: "",
      matrixRoomName: "",
      discordBotToken: "",
      discordBotTokenSet: false,
      discordGuildId: "",
      discordVoiceChannelId: "",
      publicIp: "",
      useHomeserverTurn: true,
      loading: {
        getConfiguration: false,
        configureModule: false,
      },
      error: {
        getConfiguration: "",
        configureModule: "",
        matrix_homeserver_url: "",
        matrix_access_token: "",
        matrix_allowed_user: "",
        matrix_room_name: "",
        discord_bot_token: "",
        discord_guild_id: "",
        discord_voice_channel_id: "",
        public_ip: "",
      },
    };
  },
  computed: {
    ...mapState(["instanceName", "core", "appName"]),
    busy() {
      return this.loading.getConfiguration || this.loading.configureModule;
    },
  },
  created() {
    this.getConfiguration();
  },
  beforeRouteEnter(to, from, next) {
    next((vm) => {
      vm.watchQueryData(vm);
      vm.urlCheckInterval = vm.initUrlBindingForApp(vm, vm.q.page);
    });
  },
  beforeRouteLeave(to, from, next) {
    clearInterval(this.urlCheckInterval);
    next();
  },
  methods: {
    // Start a module task and route its events to the given handlers
    async runTask(action, data, handlers, extra) {
      const eventId = this.getUuid();
      this.core.$root.$once(`${action}-aborted-${eventId}`, handlers.aborted);
      this.core.$root.$once(
        `${action}-completed-${eventId}`,
        handlers.completed
      );
      if (handlers.validationFailed) {
        this.core.$root.$once(
          `${action}-validation-failed-${eventId}`,
          handlers.validationFailed
        );
      }
      const res = await to(
        this.createModuleTaskForApp(this.instanceName, {
          action,
          data,
          extra: {
            title: this.$t("action." + action),
            isNotificationHidden: true,
            ...extra,
            eventId,
          },
        })
      );
      return res[0];
    },
    focusElement(ref) {
      const element = this.$refs[ref];
      if (element && element.focus) {
        element.focus();
      }
    },
    async getConfiguration() {
      this.loading.getConfiguration = true;
      this.error.getConfiguration = "";
      const err = await this.runTask("get-configuration", undefined, {
        aborted: this.getConfigurationAborted,
        completed: this.getConfigurationCompleted,
      });
      if (err) {
        console.error("error creating task get-configuration", err);
        this.error.getConfiguration = this.getErrorMessage(err);
        this.loading.getConfiguration = false;
      }
    },
    getConfigurationAborted(taskResult, taskContext) {
      console.error(`${taskContext.action} aborted`, taskResult);
      this.error.getConfiguration = this.$t("error.generic_error");
      this.loading.getConfiguration = false;
    },
    getConfigurationCompleted(taskContext, taskResult) {
      const config = taskResult.output;
      this.configured = config.configured;
      this.udpPorts = config.udp_ports;
      this.matrixHomeserverUrl = config.matrix_homeserver_url;
      this.matrixAccessTokenSet = config.matrix_access_token_set;
      this.matrixAllowedUser = config.matrix_allowed_user;
      this.matrixRoomName = config.matrix_room_name;
      this.discordBotTokenSet = config.discord_bot_token_set;
      this.discordGuildId = config.discord_guild_id;
      this.discordVoiceChannelId = config.discord_voice_channel_id;
      this.publicIp = config.public_ip;
      this.useHomeserverTurn = config.use_homeserver_turn;
      this.matrixAccessToken = "";
      this.discordBotToken = "";
      this.loading.getConfiguration = false;
      this.$nextTick(() => this.focusElement("matrix_homeserver_url"));
    },
    validateConfigureModule() {
      this.clearErrors(this);
      const required = {
        matrix_homeserver_url: this.matrixHomeserverUrl,
        matrix_access_token:
          this.matrixAccessToken || this.matrixAccessTokenSet,
        matrix_allowed_user: this.matrixAllowedUser,
        discord_bot_token: this.discordBotToken || this.discordBotTokenSet,
        discord_guild_id: this.discordGuildId,
        discord_voice_channel_id: this.discordVoiceChannelId,
      };
      let firstInvalid = "";
      for (const field of FIELDS) {
        if (field in required && !required[field]) {
          this.error[field] = "common.required";
          firstInvalid = firstInvalid || field;
        }
      }
      if (firstInvalid) {
        this.$nextTick(() => this.focusElement(firstInvalid));
        return false;
      }
      return true;
    },
    async configureModule() {
      if (!this.validateConfigureModule()) {
        return;
      }
      this.loading.configureModule = true;
      const data = {
        matrix_homeserver_url: this.matrixHomeserverUrl,
        matrix_allowed_user: this.matrixAllowedUser,
        matrix_room_name: this.matrixRoomName,
        discord_guild_id: this.discordGuildId,
        discord_voice_channel_id: this.discordVoiceChannelId,
        public_ip: this.publicIp,
        use_homeserver_turn: this.useHomeserverTurn,
      };
      // Empty token fields keep the saved tokens
      if (this.matrixAccessToken) {
        data.matrix_access_token = this.matrixAccessToken;
      }
      if (this.discordBotToken) {
        data.discord_bot_token = this.discordBotToken;
      }
      const err = await this.runTask(
        "configure-module",
        data,
        {
          aborted: this.configureModuleAborted,
          completed: this.configureModuleCompleted,
          validationFailed: this.configureModuleValidationFailed,
        },
        {
          title: this.$t("settings.instance_configuration"),
          description: this.$t("settings.configuring"),
          isNotificationHidden: false,
        }
      );
      if (err) {
        console.error("error creating task configure-module", err);
        this.error.configureModule = this.getErrorMessage(err);
        this.loading.configureModule = false;
      }
    },
    configureModuleValidationFailed(validationErrors) {
      this.loading.configureModule = false;
      let firstInvalid = "";
      for (const validationError of validationErrors) {
        const param = validationError.parameter;
        if (param in this.error) {
          this.error[param] = "settings." + validationError.error;
          firstInvalid = firstInvalid || param;
        }
      }
      if (firstInvalid) {
        this.$nextTick(() => this.focusElement(firstInvalid));
      }
    },
    configureModuleAborted(taskResult, taskContext) {
      console.error(`${taskContext.action} aborted`, taskResult);
      this.error.configureModule = this.$t("error.generic_error");
      this.loading.configureModule = false;
    },
    configureModuleCompleted() {
      this.loading.configureModule = false;
      this.getConfiguration();
    },
  },
};
</script>

<style scoped lang="scss">
@import "../styles/carbon-utils";

.mg-bottom {
  margin-bottom: $spacing-06;
}

.mg-bottom-sm {
  margin-bottom: $spacing-03;
}

.mg-bottom-lg {
  margin-bottom: $spacing-08;
}

.helper {
  max-width: 38rem;
}
</style>
