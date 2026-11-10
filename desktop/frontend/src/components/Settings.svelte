<script>
  import { ui, savePrefs } from '../lib/state.svelte.js'
  import { api } from '../lib/api.js'

  let { onclose } = $props()
  let confirmUnpair = $state(false)
  let version = $state('')
  api.version().then((v) => (version = v ?? '')).catch(() => {})

  function toggle(key) {
    savePrefs({ ...ui.prefs, [key]: !ui.prefs[key] })
  }
  async function unpair() {
    await api.logout()
    onclose()
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onclose()} />

<div class="sheet-backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && onclose()}>
  <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="settings-title">
    <h2 id="settings-title">Settings</h2>

    <section>
      <h3>Notifications</h3>
      <label><input type="checkbox" checked={ui.prefs.notifications} onchange={() => toggle('notifications')} /> Show notifications for new messages</label>
      <label><input type="checkbox" checked={ui.prefs.previews} onchange={() => toggle('previews')} disabled={!ui.prefs.notifications} /> Show message previews</label>
    </section>

    <section>
      <h3>General</h3>
      <label><input type="checkbox" checked={ui.prefs.enterToSend} onchange={() => toggle('enterToSend')} /> Press Enter to send (Shift+Enter for a new line)</label>
      <label><input type="checkbox" checked={ui.prefs.keepRunning} onchange={() => toggle('keepRunning')} /> Keep running when the window is closed</label>
      <p class="hint">When on, closing the window keeps the app in the system tray, connected for notifications. Click the tray icon to show it again; quit from its menu or with Ctrl+Q. Takes effect after restarting the app.</p>
      <label class="select">Link previews
        <select value={ui.prefs.linkPreviews ?? 'contacts'} onchange={(e) => savePrefs({ ...ui.prefs, linkPreviews: e.currentTarget.value })}>
          <option value="everyone">From everyone</option>
          <option value="contacts">From saved contacts</option>
          <option value="off">Off</option>
        </select>
      </label>
      <p class="hint">Loading a preview contacts the linked website, which lets it see your IP address. Links you send always preview unless this is off.</p>
    </section>

    <section>
      <h3>Phone</h3>
      {#if !confirmUnpair}
        <button class="secondary danger" onclick={() => (confirmUnpair = true)}>Unpair this computer…</button>
      {:else}
        <p>Unpair this computer from your phone? You'll need to sign in with Google again.</p>
        <div class="actions">
          <button class="secondary" onclick={() => (confirmUnpair = false)}>Cancel</button>
          <button class="primary danger-fill" onclick={unpair}>Unpair</button>
        </div>
      {/if}
    </section>

    <div class="actions">
      {#if version}<span class="version">Goob Messages {version === 'dev' ? '(development build)' : version}</span>{/if}
      <button class="primary" onclick={onclose}>Done</button>
    </div>
  </div>
</div>

<style>
  section { margin-bottom: 16px; }
  h3 { font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--text-2); margin: 0 0 8px; }
  label { display: flex; gap: 8px; align-items: flex-start; padding: 4px 0; line-height: 1.35; }
  input[type='checkbox'] { accent-color: var(--blue); margin-top: 2px; }
  label.select { align-items: center; justify-content: space-between; margin-top: 6px; }
  select { font: inherit; padding: 3px 6px; border-radius: 6px; border: 1px solid var(--sidebar-border); background: var(--bg); color: var(--text); }
  .hint { color: var(--text-3); font-size: 12px; margin: 4px 0 0 24px; }
  .actions { display: flex; justify-content: flex-end; gap: 8px; }
  .danger { color: var(--danger); }
  .version { margin-right: auto; align-self: center; font-size: 11.5px; color: var(--text-3); }
  .danger-fill { background: var(--danger); }
</style>
