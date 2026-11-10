<script>
  import { onMount, onDestroy } from 'svelte'
  import { api, on } from '../lib/api.js'
  import { ui } from '../lib/state.svelte.js'

  // step: idle | browser | starting | emoji | connecting | error
  let step = $state({ step: 'idle' })
  let off

  onMount(() => {
    off = on('signin', (s) => (step = s ?? { step: 'idle' }))
  })
  onDestroy(() => {
    off?.()
    if (step.step !== 'connecting') api.cancelPairing()
  })

  function start() {
    step = { step: 'browser' }
    api.startPairing().catch((e) => (step = { step: 'error', error: String(e?.message ?? e) }))
  }
  function cancel() {
    api.cancelPairing()
    step = { step: 'idle' }
  }
</script>

<div class="wrap">
  <div class="card">
    <div class="logo" aria-hidden="true">
      <svg viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5ac8fa"/><stop offset="1" stop-color="#0a7cff"/></linearGradient></defs><rect width="64" height="64" rx="15" fill="url(#g)"/><path d="M32 14c-11 0-20 7.4-20 16.6 0 5.2 2.9 9.9 7.5 12.9-.3 2.6-1.6 5.3-3.9 7.5 4.8-.3 8.5-2 10.9-4.2 1.7.4 3.6.6 5.5.6 11 0 20-7.4 20-16.8C52 21.4 43 14 32 14z" fill="#fff"/></svg>
    </div>
    <h1>Messages for Linux &amp; Windows</h1>

    {#if step.step === 'idle' || step.step === 'error'}
      {#if step.step === 'error'}<p class="err">{step.error}</p>
      {:else if ui.status.error}<p class="err">{ui.status.error}</p>{/if}
      <p class="sub">Sign in with the Google account that Google Messages on your Android phone uses.</p>
      <button class="primary big" onclick={start}>{step.step === 'error' ? 'Try again' : 'Sign in with Google'}</button>
      <p class="hint">Google's sign-in page opens in a separate window. Your password goes only to Google.</p>
    {:else if step.step === 'browser'}
      <div class="spinner"></div>
      <p class="sub">Finish signing in in the Google window.</p>
      <button class="secondary" onclick={cancel}>Cancel</button>
    {:else if step.step === 'starting'}
      <div class="spinner"></div>
      <p class="sub">Contacting your phone…</p>
      <button class="secondary" onclick={cancel}>Cancel</button>
    {:else if step.step === 'emoji'}
      <p class="sub">On your phone, Google Messages will ask you to confirm. <b>Tap this emoji:</b></p>
      <div class="emoji" aria-label="Emoji to tap: {step.emoji}">
        {#if step.emojiUrl}<img src={step.emojiUrl} alt={step.emoji} draggable="false" />{:else}{step.emoji}{/if}
      </div>
      <p class="hint">Keep your phone unlocked and online.</p>
      <button class="secondary" onclick={cancel}>Cancel</button>
    {:else}
      <div class="spinner"></div>
      <p class="sub">Paired! Loading your conversations…</p>
    {/if}
  </div>
</div>

<style>
  .wrap { height: 100%; display: grid; place-items: center; padding: 16px; overflow: auto; }
  .card { max-width: 420px; text-align: center; display: flex; flex-direction: column; align-items: center; gap: 4px; }
  .logo svg { width: 64px; height: 64px; }
  h1 { font-size: 21px; margin: 12px 0 6px; }
  .sub { color: var(--text-2); line-height: 1.45; margin: 8px 0 14px; }
  .sub b { color: var(--text); }
  .err { color: var(--danger); line-height: 1.4; }
  .hint { color: var(--text-3); font-size: 12px; margin-top: 14px; }
  .big { padding: 11px 26px; font-size: 15px; }
  .emoji {
    width: 150px; height: 150px; border-radius: 32px; background: var(--sidebar); display: grid; place-items: center;
    font-size: 84px; line-height: 1; box-shadow: 0 1px 0 var(--sidebar-border), 0 6px 24px rgba(0, 0, 0, 0.08);
  }
  .emoji img { width: 96px; height: 96px; }
  .spinner {
    width: 26px; height: 26px; border-radius: 50%; border: 3px solid var(--received); border-top-color: var(--blue);
    animation: spin 0.8s linear infinite; margin-top: 10px;
  }
  @keyframes spin { to { transform: rotate(360deg) } }
</style>
