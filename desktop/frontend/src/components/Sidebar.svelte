<script>
  import { ui, select, toast } from '../lib/state.svelte.js'
  import { listTime } from '../lib/format.js'
  import { api } from '../lib/api.js'
  import Avatar from './Avatar.svelte'

  let { onnew, onsettings } = $props()
  let menu = $state(null) // { x, y, conv, confirmDelete }

  const visible = $derived.by(() => {
    const q = ui.search.trim().toLowerCase()
    return ui.conversations.filter((c) => {
      if (!!c.archived !== ui.showArchived) return false
      if (!q) return true
      return (c.name ?? '').toLowerCase().includes(q) || (c.preview ?? '').toLowerCase().includes(q) ||
        (c.participants ?? []).some((p) => p.toLowerCase().includes(q))
    })
  })
  const archivedCount = $derived(ui.conversations.filter((c) => c.archived).length)

  function onKey(e) {
    if (e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return
    e.preventDefault()
    const i = visible.findIndex((c) => c.id === ui.selectedId)
    const next = visible[Math.max(0, Math.min(visible.length - 1, i + (e.key === 'ArrowDown' ? 1 : -1)))]
    if (next) select(next.id)
  }

  function openMenu(e, conv) {
    e.preventDefault()
    menu = { x: Math.min(e.clientX, window.innerWidth - 220), y: Math.min(e.clientY, window.innerHeight - 200), conv, confirmDelete: false }
  }

  async function archive(conv) {
    menu = null
    try {
      await api.setArchived(conv.id, !conv.archived)
      if (ui.selectedId === conv.id && !conv.archived) select('')
    } catch (e) { toast(e) }
  }

  async function remove(conv) {
    menu = null
    try {
      await api.deleteConversation(conv.id)
      if (ui.selectedId === conv.id) select('')
    } catch (e) { toast(e) }
  }

  function toggleAlerts(conv) {
    const hidden = { ...(ui.prefs.hiddenAlerts ?? {}) }
    const hide = !hidden[conv.id]
    if (hide) hidden[conv.id] = true
    else delete hidden[conv.id]
    ui.prefs.hiddenAlerts = hidden
    api.hideAlerts(conv.id, hide)
    menu = null
  }
</script>

<svelte:window onclick={() => (menu = null)} />

<aside>
  <header>
    <div class="search">
      <svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="m13 13 4 4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>
      <input id="search" placeholder="Search" bind:value={ui.search} spellcheck="false" autocomplete="off" />
    </div>
    <button class="icon-btn" title="New message (Ctrl+N)" aria-label="New message" onclick={onnew}>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>
    </button>
  </header>

  {#if ui.showArchived}
    <button class="back" onclick={() => (ui.showArchived = false)}>‹ Archived</button>
  {/if}

  <div class="list scroll" role="listbox" tabindex="0" aria-label="Conversations" onkeydown={onKey}>
    {#each visible as c (c.id)}
      <button
        class="row"
        class:selected={c.id === ui.selectedId}
        role="option"
        aria-selected={c.id === ui.selectedId}
        onclick={() => select(c.id)}
        oncontextmenu={(e) => openMenu(e, c)}
      >
        <span class="dot" class:on={c.unread && c.id !== ui.selectedId}></span>
        <Avatar conv={c} size={40} />
        <span class="text">
          <span class="top">
            <span class="name">{c.name || 'Unknown'}</span>
            {#if ui.prefs.hiddenAlerts?.[c.id]}<span class="muted" title="Alerts hidden">🔕</span>{/if}
            <span class="time">{listTime(c.timestamp)}</span>
          </span>
          <span class="preview">
            {#if ui.typing[c.id] > Date.now()}<i>typing…</i>{:else}{c.preview}{/if}
          </span>
        </span>
      </button>
    {:else}
      <p class="empty">{ui.search ? 'No results' : ui.status.phase === 'ready' ? 'No conversations' : 'Loading…'}</p>
    {/each}
  </div>

  <footer>
    {#if !ui.showArchived && archivedCount > 0}
      <button class="foot-btn" onclick={() => (ui.showArchived = true)}>Archived ({archivedCount})</button>
    {:else}<span></span>{/if}
    <button class="icon-btn" title="Settings (Ctrl+,)" aria-label="Settings" onclick={onsettings}>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>
    </button>
  </footer>
</aside>

{#if menu}
  <div class="menu" style="left:{menu.x}px;top:{menu.y}px" role="menu">
    <button role="menuitem" onclick={() => { api.markRead(menu.conv.id); menu = null }}>Mark as Read</button>
    <button role="menuitem" onclick={() => toggleAlerts(menu.conv)}>
      {ui.prefs.hiddenAlerts?.[menu.conv.id] ? 'Show Alerts' : 'Hide Alerts'}
    </button>
    <button role="menuitem" onclick={() => archive(menu.conv)}>{menu.conv.archived ? 'Unarchive' : 'Archive'}</button>
    <div class="sepline"></div>
    {#if !menu.confirmDelete}
      <button role="menuitem" class="danger" onclick={(e) => { e.stopPropagation(); menu.confirmDelete = true }}>Delete Conversation…</button>
    {:else}
      <button role="menuitem" class="danger-fill" onclick={() => remove(menu.conv)}>Delete from phone</button>
    {/if}
  </div>
{/if}

<style>
  aside { background: var(--sidebar); border-right: 1px solid var(--sidebar-border); display: flex; flex-direction: column; min-width: 0; height: 100%; }
  header { display: flex; gap: 6px; align-items: center; padding: 12px 10px 8px 12px; }
  .search { flex: 1; display: flex; align-items: center; gap: 6px; background: var(--hover); border-radius: 8px; padding: 0 8px; height: 30px; color: var(--text-3); }
  .search svg { width: 14px; height: 14px; flex: none; }
  .search input { border: none; background: transparent; outline: none; width: 100%; color: var(--text); }
  .back { border: none; background: none; color: var(--blue); text-align: left; padding: 2px 14px 8px; font-weight: 600; }
  .list { flex: 1; padding: 0 8px; outline: none; }
  .row {
    width: 100%; display: flex; align-items: center; gap: 9px; border: none; background: none; text-align: left;
    padding: 9px 8px 9px 2px; border-radius: 10px; position: relative;
  }
  .row:hover { background: var(--hover); }
  .row.selected { background: var(--blue); color: white; }
  .row.selected .preview, .row.selected .time { color: rgba(255, 255, 255, 0.82); }
  .dot { width: 9px; height: 9px; border-radius: 50%; flex: none; }
  .dot.on { background: var(--blue); }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
  .top { display: flex; align-items: baseline; gap: 6px; }
  .name { font-weight: 600; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .muted { font-size: 11px; }
  .time { font-size: 12px; color: var(--text-2); flex: none; }
  .preview {
    color: var(--text-2); font-size: 13px; line-height: 1.3; display: -webkit-box; -webkit-line-clamp: 2; line-clamp: 2;
    -webkit-box-orient: vertical; overflow: hidden; overflow-wrap: anywhere; min-height: 2.6em;
  }
  .empty { color: var(--text-3); text-align: center; margin-top: 40px; }
  footer { display: flex; justify-content: space-between; align-items: center; padding: 6px 10px; border-top: 1px solid var(--sidebar-border); }
  .foot-btn { border: none; background: none; color: var(--text-2); font-size: 12.5px; padding: 4px 6px; border-radius: 6px; }
  .foot-btn:hover { background: var(--hover); }
  .menu {
    position: fixed; z-index: 40; background: var(--bg); border: 1px solid var(--sidebar-border); border-radius: 10px;
    box-shadow: var(--shadow); padding: 5px; display: flex; flex-direction: column; min-width: 170px;
  }
  .menu button { border: none; background: none; text-align: left; padding: 6px 10px; border-radius: 6px; }
  .menu button:hover { background: var(--blue); color: white; }
  .menu .danger { color: var(--danger); }
  .menu .danger-fill { background: var(--danger); color: white; font-weight: 600; }
  .sepline { height: 1px; background: var(--sidebar-border); margin: 4px 2px; }
</style>
