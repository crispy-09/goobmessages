<script>
  import { onMount } from 'svelte'
  import { ui, init } from './lib/state.svelte.js'
  import { api } from './lib/api.js'
  import Login from './components/Login.svelte'
  import Sidebar from './components/Sidebar.svelte'
  import Chat from './components/Chat.svelte'
  import Settings from './components/Settings.svelte'
  import NewChat from './components/NewChat.svelte'

  let showSettings = $state(false)
  let showNew = $state(false)
  let sidebarWidth = $state(300)

  onMount(() => {
    init()
    try {
      const w = Number(localStorage.getItem('sidebarWidth'))
      if (w >= 220 && w <= 480) sidebarWidth = w
    } catch {}
  })

  function onKey(e) {
    const mod = e.ctrlKey || e.metaKey
    if (!mod) return
    if (e.key === 'n' && ui.status.phase === 'ready') { e.preventDefault(); showNew = true }
    else if (e.key === ',') { e.preventDefault(); showSettings = true }
    else if (e.key === 'q') { e.preventDefault(); api.quit() }
    else if (e.key === 'f' && !e.shiftKey) { e.preventDefault(); document.getElementById('search')?.focus() }
  }

  function startResize(e) {
    const startX = e.clientX, startW = sidebarWidth
    const move = (ev) => (sidebarWidth = Math.min(480, Math.max(220, startW + ev.clientX - startX)))
    const up = () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', up)
      try { localStorage.setItem('sidebarWidth', String(sidebarWidth)) } catch {}
    }
    window.addEventListener('pointermove', move)
    window.addEventListener('pointerup', up)
  }
</script>

<svelte:window onkeydown={onKey} />

{#if ui.status.phase === 'loading'}
  <div class="center"><div class="spinner"></div></div>
{:else if ui.status.phase === 'login'}
  <Login />
{:else}
  <div class="layout" style="--sidebar-w: {sidebarWidth}px">
    <Sidebar onnew={() => (showNew = true)} onsettings={() => (showSettings = true)} />
    <div class="resizer" role="separator" aria-orientation="vertical" onpointerdown={startResize}></div>
    <main>
      {#if ui.status.phase === 'connecting'}
        <div class="banner">Connecting to your phone…</div>
      {:else if ui.status.inactive}
        <div class="banner">
          Messages is open in another browser or app.
          <button class="link" onclick={() => api.useHere()}>Use here</button>
        </div>
      {:else if ui.status.banner}
        <div class="banner">{ui.status.banner}</div>
      {/if}
      <Chat onnew={() => (showNew = true)} />
    </main>
  </div>
{/if}

{#if showSettings}<Settings onclose={() => (showSettings = false)} />{/if}
{#if showNew}<NewChat onclose={() => (showNew = false)} />{/if}

{#if ui.toast}
  <div class="toast" role="alert">{ui.toast}</div>
{/if}

<style>
  .center { height: 100%; display: grid; place-items: center; }
  .spinner {
    width: 26px; height: 26px; border-radius: 50%; border: 3px solid var(--received); border-top-color: var(--blue);
    animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg) } }
  .layout { display: grid; grid-template-columns: var(--sidebar-w) 0 minmax(0, 1fr); grid-template-rows: minmax(0, 1fr); height: 100%; }
  .resizer { width: 6px; margin-left: -3px; cursor: col-resize; z-index: 5; }
  main { display: flex; flex-direction: column; min-width: 0; min-height: 0; height: 100%; overflow: hidden; }
  .banner {
    background: var(--banner); color: var(--banner-text); padding: 7px 14px; font-size: 12.5px; text-align: center;
    border-bottom: 1px solid var(--sidebar-border);
  }
  .link { background: none; border: none; color: var(--blue); font-weight: 600; padding: 0 4px; }
  .toast {
    position: fixed; bottom: 86px; left: 50%; transform: translateX(-50%); z-index: 60;
    background: #1c1c1e; color: white; padding: 9px 16px; border-radius: 10px; box-shadow: var(--shadow);
    max-width: min(520px, calc(100vw - 32px)); font-size: 13px; animation: fade 0.15s;
  }
  @media (max-width: 720px) {
    .layout { grid-template-columns: min(var(--sidebar-w), 42vw) 0 1fr; }
  }
</style>
