import { createSignal, Show, type Component } from 'solid-js';
import { t } from '../i18n';
import type { AppConfig } from '../api/client';
import { createConfigTab } from '../state/configTab';
import { TabShell } from '../components/layout/TabShell';
import { PageHeader } from '../components/ui/PageHeader';
import { StaticConfigBlock } from '../components/ui/ConfigBlocks';
import { TextInput } from '../components/ui/FormField';
import { Switch } from '../components/ui/Switch';
import { SavePanel } from '../components/ui/SavePanel';
import { Banner } from '../components/ui/Banner';
import { pushToast } from '../state/toast';

type HaForm = {
  ha_enabled: boolean;
  ha_base_url: string;
  ha_token: string;
};

function boolFromConfig(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined || value === '') return fallback;
  return value !== 'false';
}

export const HaPage: Component = () => {
  const tab = createConfigTab<HaForm>({
    tab: 'ha',
    groups: ['ha'],
    toForm: (config: Partial<AppConfig>) => ({
      ha_enabled: boolFromConfig(config.ha_enabled, true),
      ha_base_url: config.ha_base_url ?? '',
      ha_token: config.ha_token ?? '',
    }),
    fromForm: (form) => ({
      ha_enabled: form.ha_enabled ? 'true' : 'false',
      ha_base_url: form.ha_base_url.trim(),
      ha_token: form.ha_token,
    }),
  });
  const [validationError, setValidationError] = createSignal<string | null>(null);

  const handleSave = async () => {
    if (tab.form.ha_enabled && !tab.form.ha_base_url.trim()) {
      const message = t('haValidationBaseUrlRequired') as string;
      setValidationError(message);
      pushToast(message, 'error', 5000);
      return;
    }
    setValidationError(null);
    await tab.save();
  };

  return (
    <TabShell>
      <PageHeader
        title={t('sectionHa') as string}
        description={t('haDescription') as string}
      />
      <Show when={validationError() ?? tab.error()}>
        <div class="px-5 pt-4">
          <Banner kind="error" message={validationError() ?? tab.error() ?? undefined} />
        </div>
      </Show>
      <div class="divide-y divide-[var(--color-border-subtle)] mt-2">
        <StaticConfigBlock title={t('sectionHaGeneral') as string}>
          <div class="pt-2 flex flex-col gap-4">
            <Switch
              checked={tab.form.ha_enabled}
              label={t('haEnable') as string}
              hint={t('haEnableHint') as string}
              onChange={(checked) => tab.setForm('ha_enabled', checked)}
            />
            <div class="grid gap-3 sm:grid-cols-2">
              <TextInput
                full
                label={t('haBaseUrl')}
                placeholder={t('haBaseUrlPlaceholder') as string}
                autocomplete="off"
                value={tab.form.ha_base_url}
                onInput={(event) => tab.setForm('ha_base_url', event.currentTarget.value)}
              />
              <TextInput
                full
                type="password"
                label={t('haToken')}
                hint={t('haTokenHint') as string}
                autocomplete="new-password"
                value={tab.form.ha_token}
                onInput={(event) => tab.setForm('ha_token', event.currentTarget.value)}
              />
            </div>
          </div>
        </StaticConfigBlock>
      </div>
      <SavePanel
        dirty={tab.dirty()}
        saving={tab.saving()}
        onSave={() => handleSave().catch(() => undefined)}
        onDiscard={tab.discard}
      />
    </TabShell>
  );
};
