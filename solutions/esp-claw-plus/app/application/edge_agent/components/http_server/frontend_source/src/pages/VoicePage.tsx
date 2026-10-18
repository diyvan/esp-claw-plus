import { Show, type Component } from 'solid-js';
import { t } from '../i18n';
import type { AppConfig } from '../api/client';
import { createConfigTab } from '../state/configTab';
import { TabShell } from '../components/layout/TabShell';
import { PageHeader } from '../components/ui/PageHeader';
import { CollapsibleConfigBlock, StaticConfigBlock } from '../components/ui/ConfigBlocks';
import { TextInput, SelectInput } from '../components/ui/FormField';
import { Switch } from '../components/ui/Switch';
import { SavePanel } from '../components/ui/SavePanel';
import { Banner } from '../components/ui/Banner';

type VoiceForm = {
  voice_enabled: boolean;
  voice_wake_enabled: boolean;
  voice_reply_mode: string;
  voice_asr_provider: string;
  voice_asr_url: string;
  voice_asr_api_key: string;
  voice_asr_resource_id: string;
  voice_tts_engine: string;
  voice_tts_provider: string;
  voice_tts_url: string;
  voice_tts_api_key: string;
  voice_tts_resource_id: string;
  voice_tts_speaker: string;
  voice_tts_stream: boolean;
};

function boolFromConfig(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined || value === '') return fallback;
  return value !== 'false';
}

// Empty / "generic" both mean the built-in generic provider; normalize to "generic"
// so the dropdown always has a matching option.
function providerFromConfig(value: string | undefined): string {
  return value === 'volcano' ? 'volcano' : 'generic';
}

// TTS engine: "local" = on-device esp-tts (streaming playback only, lowest latency);
// anything else = cloud TTS. Settings for both live in the same config field
// (voice_tts_provider), so the engine selector is a view over that value.
function ttsEngineFromConfig(value: string | undefined): string {
  return value === 'local' ? 'local' : 'cloud';
}

// Reply mode: "agent" (full agent loop) or "direct" (single LLM round-trip).
// Defaults to "agent" when unset.
function replyModeFromConfig(value: string | undefined): string {
  return value === 'direct' ? 'direct' : 'agent';
}

export const VoicePage: Component = () => {
  const tab = createConfigTab<VoiceForm>({
    tab: 'voice',
    groups: ['voice'],
    toForm: (config: Partial<AppConfig>) => ({
      voice_enabled: boolFromConfig(config.voice_enabled, true),
      voice_wake_enabled: boolFromConfig(config.voice_wake_enabled, true),
      voice_reply_mode: replyModeFromConfig(config.voice_reply_mode),
      voice_tts_stream: boolFromConfig(config.voice_tts_stream, false),
      voice_asr_provider: providerFromConfig(config.voice_asr_provider),
      voice_asr_url: config.voice_asr_url ?? '',
      voice_asr_api_key: config.voice_asr_api_key ?? '',
      voice_asr_resource_id: config.voice_asr_resource_id ?? '',
      voice_tts_engine: ttsEngineFromConfig(config.voice_tts_provider),
      voice_tts_provider: providerFromConfig(config.voice_tts_provider),
      voice_tts_url: config.voice_tts_url ?? '',
      voice_tts_api_key: config.voice_tts_api_key ?? '',
      voice_tts_resource_id: config.voice_tts_resource_id ?? '',
      voice_tts_speaker: config.voice_tts_speaker ?? '',
    }),
    fromForm: (form) => ({
      voice_enabled: form.voice_enabled ? 'true' : 'false',
      voice_wake_enabled: form.voice_wake_enabled ? 'true' : 'false',
      voice_reply_mode: form.voice_reply_mode,
      voice_tts_stream: form.voice_tts_stream ? 'true' : 'false',
      voice_asr_provider: form.voice_asr_provider,
      voice_asr_url: form.voice_asr_url.trim(),
      voice_asr_api_key: form.voice_asr_api_key,
      voice_asr_resource_id: form.voice_asr_resource_id.trim(),
      voice_tts_provider: form.voice_tts_engine === 'local' ? 'local' : form.voice_tts_provider,
      voice_tts_url: form.voice_tts_url.trim(),
      voice_tts_api_key: form.voice_tts_api_key,
      voice_tts_resource_id: form.voice_tts_resource_id.trim(),
      voice_tts_speaker: form.voice_tts_speaker.trim(),
    }),
  });

  return (
    <TabShell>
      <PageHeader
        title={t('sectionVoice') as string}
        description={t('voiceDescription') as string}
      />
      <div class="divide-y divide-[var(--color-border-subtle)] mt-2">
        <StaticConfigBlock title={t('voiceGeneralSection') as string}>
          <div class="pt-2">
            <Switch
              checked={tab.form.voice_enabled}
              label={t('voiceEnable') as string}
              hint={t('voiceEnableHint') as string}
              onChange={(checked) => tab.setForm('voice_enabled', checked)}
            />
          </div>
          <div class="pt-3">
            <SelectInput
              label={t('voiceReplyMode')}
              hint={t('voiceReplyModeHint')}
              value={tab.form.voice_reply_mode}
              onChange={(event) => tab.setForm('voice_reply_mode', event.currentTarget.value)}
            >
              <option value="agent">{t('voiceReplyModeAgent') as string}</option>
              <option value="direct">{t('voiceReplyModeDirect') as string}</option>
            </SelectInput>
          </div>
        </StaticConfigBlock>
        <StaticConfigBlock title={t('voiceWakeSection') as string}>
          <div class="pt-2">
            <Switch
              checked={tab.form.voice_wake_enabled}
              label={t('voiceWakeEnable') as string}
              hint={t('voiceWakeHint') as string}
              onChange={(checked) => tab.setForm('voice_wake_enabled', checked)}
            />
          </div>
        </StaticConfigBlock>
        <CollapsibleConfigBlock title={t('voiceAsrSection') as string} defaultOpen={true}>
          <div class="pt-2 grid gap-3 sm:grid-cols-2">
            <SelectInput
              label={t('voiceAsrProvider')}
              hint={t('voiceProviderHint')}
              value={tab.form.voice_asr_provider}
              onChange={(event) => tab.setForm('voice_asr_provider', event.currentTarget.value)}
            >
              <option value="generic">{t('voiceProviderGeneric') as string}</option>
              <option value="volcano">{t('voiceProviderVolcano') as string}</option>
            </SelectInput>
            <Show when={tab.form.voice_asr_provider === 'volcano'}>
              <TextInput
                label={t('voiceAsrResourceId')}
                placeholder={t('voiceAsrResourceIdPlaceholder') as string}
                autocomplete="off"
                value={tab.form.voice_asr_resource_id}
                onInput={(event) =>
                  tab.setForm('voice_asr_resource_id', event.currentTarget.value)
                }
              />
            </Show>
            <TextInput
              full
              label={t('voiceAsrUrl')}
              placeholder={t(
                tab.form.voice_asr_provider === 'volcano'
                  ? 'voiceAsrUrlPlaceholderVolcano'
                  : 'voiceAsrUrlPlaceholder',
              ) as string}
              autocomplete="off"
              value={tab.form.voice_asr_url}
              onInput={(event) => tab.setForm('voice_asr_url', event.currentTarget.value)}
            />
            <TextInput
              full
              type="password"
              label={t('voiceAsrApiKey')}
              autocomplete="new-password"
              value={tab.form.voice_asr_api_key}
              onInput={(event) => tab.setForm('voice_asr_api_key', event.currentTarget.value)}
            />
          </div>
        </CollapsibleConfigBlock>
        <CollapsibleConfigBlock title={t('voiceTtsSection') as string} defaultOpen={true}>
          <div class="pt-2">
            <SelectInput
              label={t('voiceTtsEngine')}
              hint={t('voiceTtsEngineHint')}
              value={tab.form.voice_tts_engine}
              onChange={(event) => tab.setForm('voice_tts_engine', event.currentTarget.value)}
            >
              <option value="cloud">{t('voiceTtsEngineCloud') as string}</option>
              <option value="local">{t('voiceTtsEngineLocal') as string}</option>
            </SelectInput>
          </div>
          <Show when={tab.form.voice_tts_engine === 'cloud'}>
            <div class="pt-2">
              <Switch
                checked={tab.form.voice_tts_stream}
                label={t('voiceTtsStream') as string}
                hint={t('voiceTtsStreamHint') as string}
                onChange={(checked) => tab.setForm('voice_tts_stream', checked)}
              />
            </div>
            <div class="pt-2 grid gap-3 sm:grid-cols-2">
              <SelectInput
                label={t('voiceTtsProvider')}
                hint={t('voiceProviderHint')}
                value={tab.form.voice_tts_provider}
                onChange={(event) => tab.setForm('voice_tts_provider', event.currentTarget.value)}
              >
                <option value="generic">{t('voiceProviderGeneric') as string}</option>
                <option value="volcano">{t('voiceProviderVolcano') as string}</option>
              </SelectInput>
              <Show when={tab.form.voice_tts_provider === 'volcano'}>
                <TextInput
                  label={t('voiceTtsResourceId')}
                  placeholder={t('voiceTtsResourceIdPlaceholder') as string}
                  autocomplete="off"
                  value={tab.form.voice_tts_resource_id}
                  onInput={(event) =>
                    tab.setForm('voice_tts_resource_id', event.currentTarget.value)
                  }
                />
                <TextInput
                  label={t('voiceTtsSpeaker')}
                  placeholder={t('voiceTtsSpeakerPlaceholder') as string}
                  autocomplete="off"
                  value={tab.form.voice_tts_speaker}
                  onInput={(event) => tab.setForm('voice_tts_speaker', event.currentTarget.value)}
                />
              </Show>
              <TextInput
                full
                label={t('voiceTtsUrl')}
                placeholder={t(
                  tab.form.voice_tts_provider === 'volcano'
                    ? 'voiceTtsUrlPlaceholderVolcano'
                    : 'voiceTtsUrlPlaceholder',
                ) as string}
                autocomplete="off"
                value={tab.form.voice_tts_url}
                onInput={(event) => tab.setForm('voice_tts_url', event.currentTarget.value)}
              />
              <TextInput
                full
                type="password"
                label={t('voiceTtsApiKey')}
                autocomplete="new-password"
                value={tab.form.voice_tts_api_key}
                onInput={(event) => tab.setForm('voice_tts_api_key', event.currentTarget.value)}
              />
            </div>
          </Show>
        </CollapsibleConfigBlock>
      </div>
      <Show when={tab.error()}>
        <div class="px-5 pt-4">
          <Banner kind="error" message={tab.error() ?? undefined} />
        </div>
      </Show>
      <SavePanel
        dirty={tab.dirty()}
        saving={tab.saving()}
        onSave={() => tab.save().catch(() => undefined)}
        onDiscard={tab.discard}
        note={t('voiceSaveNote') as string}
      />
    </TabShell>
  );
};
