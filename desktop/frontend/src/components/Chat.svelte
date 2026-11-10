<script>
  import { tick, onMount, untrack } from 'svelte'
  import { ui, loadOlder, toast, retryLoad } from '../lib/state.svelte.js'
  import { api, onFileDrop } from '../lib/api.js'
  import { previewAllowed } from '../lib/previews.svelte.js'
  import { separatorTime } from '../lib/format.js'
  import Avatar from './Avatar.svelte'
  import MessageRow from './MessageRow.svelte'
  import Composer from './Composer.svelte'
  import MediaView from './MediaView.svelte'

  let { onnew } = $props()

  let scroller = $state()
  let loadingOlder = $state(false)
  let replyTo = $state(null)
  let viewing = $state(null) // { url, mime, name, media }
  let menu = $state(null) // { x, y, msg }
  let dragOver = $state(false)
  let highlightId = $state('')
  let findOpen = $state(false)
  let findQuery = $state('')
  let findIndex = $state(0)
  let findInput = $state()

  const conv = $derived(ui.conversations.find((c) => c.id === ui.selectedId))
  const messages = $derived(ui.messages[ui.selectedId] ?? [])
  const byId = $derived(Object.fromEntries(messages.map((m) => [m.id, m])))
  const typing = $derived((ui.typing[ui.selectedId] ?? 0) > Date.now())

  // Precompute layout: separators (gap > 15 min), sender names in groups, tails on the last bubble of a run,
  // and the status line under the newest outgoing message.
  const rows = $derived.by(() => {
    const out = []
    let lastOutgoing = -1
    messages.forEach((m, i) => { if (m.fromMe && !m.tombstone) lastOutgoing = i })
    messages.forEach((m, i) => {
      const prev = messages[i - 1]
      const next = messages[i + 1]
      const gapBefore = !prev || m.timestamp - prev.timestamp > 15 * 60 * 1000
      const sameAsNext = next && !next.tombstone && next.fromMe === m.fromMe && next.participantId === m.participantId &&
        next.timestamp - m.timestamp < 15 * 60 * 1000
      const sameAsPrev = prev && !gapBefore && !prev.tombstone && prev.fromMe === m.fromMe && prev.participantId === m.participantId
      out.push({
        m,
        separator: gapBefore ? separatorTime(m.timestamp) : '',
        tail: !sameAsNext,
        showName: conv?.isGroup && !m.fromMe && !sameAsPrev,
        showStatus: i === lastOutgoing || m.state === 'failed',
        replyTo: m.replyToId ? byId[m.replyToId] : null,
        previewOK: previewAllowed(ui.prefs.linkPreviews ?? 'contacts', m, conv),
      })
    })
    return out
  })

  // The message list is laid out bottom-up (flex-direction: column-reverse), so the browser itself keeps the
  // newest message in view as content grows (images loading, new messages) and older pages load above without
  // moving what you're reading. scrollTop is 0 at the bottom and negative when scrolled up.
  let lastId = ''
  $effect(() => {
    const id = ui.selectedId
    if (!scroller || id === lastId) return
    lastId = id
    replyTo = null
    scroller.scrollTop = 0
    untrack(maybeLoadOlder)
  })

  // After a page arrives, if the content still doesn't reach the top of the view, fetch another.
  $effect(() => {
    messages.length
    if (scroller) tick().then(maybeLoadOlder)
  })

  function distanceFromTop() {
    return scroller.scrollHeight - scroller.clientHeight - Math.abs(scroller.scrollTop)
  }

  async function maybeLoadOlder() {
    const id = ui.selectedId
    if (!scroller || loadingOlder || !id || !ui.messages[id] || ui.hasMore[id] === false) return
    if (distanceFromTop() > 400) return
    loadingOlder = true
    try {
      await loadOlder(id)
    } finally {
      loadingOlder = false
    }
  }

  function onScroll() {
    maybeLoadOlder()
  }

  // Find in conversation (Ctrl+Shift+F): searches the loaded messages, newest match first.
  const findMatches = $derived.by(() => {
    const q = findQuery.trim().toLowerCase()
    if (!findOpen || !q) return []
    return messages.filter((m) => !m.tombstone && m.text?.toLowerCase().includes(q)).map((m) => m.id).reverse()
  })

  async function openFind() {
    findOpen = true
    await tick()
    findInput?.focus()
    findInput?.select()
  }
  function closeFind() {
    findOpen = false
    findQuery = ''
  }
  function findStep(dir) {
    if (!findMatches.length) return
    findIndex = (findIndex + dir + findMatches.length) % findMatches.length
    jumpTo(findMatches[findIndex], true)
  }
  function onFindKey(e) {
    if (e.key === 'Enter') { e.preventDefault(); findStep(e.shiftKey ? -1 : 1) }
    else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeFind() }
  }
  $effect(() => {
    findQuery
    findIndex = -1
  })
  $effect(() => {
    ui.selectedId
    untrack(closeFind)
  })
  function onWindowKey(e) {
    if ((e.ctrlKey || e.metaKey) && e.shiftKey && (e.key === 'F' || e.key === 'f') && conv) {
      e.preventDefault()
      openFind()
    }
  }

  // Scroll to a replied-to message, paging in older history until it's loaded, then flash it.
  async function jumpTo(id, quiet = false) {
    const cid = ui.selectedId
    if (!id || !scroller) return
    const find = () => scroller.querySelector(`[data-mid="${CSS.escape(id)}"]`)
    for (let i = 0; i < 25 && !find(); i++) {
      if (ui.selectedId !== cid || ui.hasMore[cid] === false) break
      loadingOlder = true
      let more
      try { more = await loadOlder(cid) } finally { loadingOlder = false }
      await tick()
      if (!more) break
    }
    const el = find()
    if (!el || ui.selectedId !== cid) {
      if (!quiet) toast("Couldn't find the original message")
      return
    }
    el.scrollIntoView({ block: 'center', behavior: 'smooth' })
    highlightId = ''
    await tick()
    highlightId = id
    setTimeout(() => { if (highlightId === id) highlightId = '' }, 1700)
  }

  function openMenu(e, msg) {
    e.preventDefault()
    menu = { x: Math.min(e.clientX, window.innerWidth - 250), y: Math.min(e.clientY, window.innerHeight - 330), msg, more: false }
  }

  const QUICK = ['❤️', '👍', '👎', '😂', '😮', '😢']
  const MORE = ['😍', '🤔', '😡', '😠', '🔥', '🎉', '🙏', '👏', '💯', '👀', '🥺', '😭', '🤣', '😊', '😎', '🤯', '🥳', '💀', '🤝', '✅', '❌', '💔', '😬', '🙌']
  async function react(msg, emoji) {
    menu = null
    const mine = msg.reactions?.find((r) => r.byMe)
    try {
      await api.react(ui.selectedId, msg.id, emoji, mine?.emoji === emoji)
    } catch (e) { toast(e) }
  }

  async function del(msg) {
    menu = null
    try { await api.deleteMessage(ui.selectedId, msg.id) } catch (e) { toast(e) }
  }

  function copy(msg) {
    menu = null
    navigator.clipboard?.writeText(msg.text).catch(() => {})
  }

  async function save(media) {
    menu = null
    try { await api.saveMedia(media.id, media.key, media.name || 'attachment') } catch (e) { toast(e) }
  }

  onMount(() => onFileDrop(async (paths) => {
    dragOver = false
    if (!ui.selectedId || !paths?.length) return
    try { await api.sendFiles(ui.selectedId, paths) } catch (e) { toast(e) }
  }))
</script>

<svelte:window onclick={() => (menu = null)} onkeydown={onWindowKey} />

{#if !conv}
  <div class="placeholder">
    <p>Select a conversation</p>
    <button class="secondary" onclick={onnew}>New message</button>
  </div>
{:else}
  <header>
    <Avatar {conv} size={30} />
    <div class="title">
      <div class="name">{conv.name || 'Unknown'}</div>
      {#if conv.isGroup && conv.participants?.length}
        <div class="sub">{conv.participants.length} people</div>
      {:else}
        <div class="sub">{conv.isRcs ? 'RCS' : 'Text message · SMS/MMS'}</div>
      {/if}
    </div>
    {#if findOpen}
      <div class="find" role="search">
        <input bind:this={findInput} bind:value={findQuery} onkeydown={onFindKey} placeholder="Find in conversation" spellcheck="false" />
        <span class="count">{findQuery.trim() ? (!findMatches.length ? 'No matches' : findIndex < 0 ? `${findMatches.length} match${findMatches.length === 1 ? '' : 'es'}` : `${findIndex + 1} of ${findMatches.length}`) : ''}</span>
        <button class="icon-btn" aria-label="Previous match" title="Older (Enter)" onclick={() => findStep(1)} disabled={!findMatches.length}>▲</button>
        <button class="icon-btn" aria-label="Next match" title="Newer (Shift+Enter)" onclick={() => findStep(-1)} disabled={!findMatches.length}>▼</button>
        <button class="icon-btn" aria-label="Close find" onclick={closeFind}>✕</button>
      </div>
    {:else}
      <button class="icon-btn find-btn" title="Find in conversation (Ctrl+Shift+F)" aria-label="Find in conversation" onclick={openFind}>
        <svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="m13 13 4 4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>
      </button>
    {/if}
  </header>

  <div
    class="messages scroll"
    class:drop={dragOver}
    style="--wails-drop-target: drop"
    bind:this={scroller}
    onscroll={onScroll}
    ondragenter={() => (dragOver = true)}
    ondragleave={(e) => { if (e.currentTarget === e.target) dragOver = false }}
    role="log"
    aria-live="polite"
  >
   <div class="content">
    {#if ui.loadState[ui.selectedId] === 'loading' && !messages.length}
      <div class="state">Loading messages…</div>
    {:else if ui.loadState[ui.selectedId] === 'error' && !messages.length}
      <div class="state">
        <p>Couldn't load this conversation.</p>
        <p class="err">{ui.loadError[ui.selectedId]}</p>
        <button class="secondary" onclick={() => retryLoad(ui.selectedId)}>Try again</button>
      </div>
    {:else if ui.hasMore[ui.selectedId] === false && messages.length}
      <div class="sep">Beginning of conversation</div>
    {:else if loadingOlder}
      <div class="sep">Loading…</div>
    {/if}
    {#each rows as r (r.m.id)}
      {#if r.separator}<div class="sep">{r.separator}</div>{/if}
      <MessageRow
        row={r}
        isGroup={conv.isGroup}
        onmenu={(e) => openMenu(e, r.m)}
        onview={(v) => (viewing = v)}
        onreact={(emoji) => react(r.m, emoji)}
        onjump={jumpTo}
        previewOK={r.previewOK}
        highlight={highlightId === r.m.id}
      />
    {/each}
    {#if typing}
      <div class="typing"><span></span><span></span><span></span></div>
    {/if}
   </div>
  </div>

  <Composer {conv} bind:replyTo replyMessage={replyTo ? byId[replyTo] : null} />
{/if}

{#if menu}
  <div class="menu" style="left:{menu.x}px;top:{menu.y}px" role="menu">
    <div class="quick">
      {#each QUICK as e}
        <button class:mine={menu.msg.reactions?.some((r) => r.byMe && r.emoji === e)} onclick={() => react(menu.msg, e)}>{e}</button>
      {/each}
      <button class="more" title="More reactions" aria-label="More reactions" onclick={(ev) => { ev.stopPropagation(); menu.more = !menu.more }}>{menu.more ? '−' : '+'}</button>
    </div>
    {#if menu.more}
      <div class="more-grid">
        {#each MORE as e}
          <button class:mine={menu.msg.reactions?.some((r) => r.byMe && r.emoji === e)} onclick={() => react(menu.msg, e)}>{e}</button>
        {/each}
      </div>
    {/if}
    {#if !menu.msg.local}<button role="menuitem" onclick={() => { replyTo = menu.msg.id; menu = null }}>Reply</button>{/if}
    {#if menu.msg.text}<button role="menuitem" onclick={() => copy(menu.msg)}>Copy</button>{/if}
    {#each menu.msg.media ?? [] as md}
      {#if md.id}<button role="menuitem" onclick={() => save(md)}>Save {md.mime?.startsWith('image/') ? 'Image' : 'Attachment'}…</button>{/if}
    {/each}
    <button role="menuitem" class="danger" onclick={() => del(menu.msg)}>Delete</button>
  </div>
{/if}

{#if viewing}<MediaView item={viewing} onclose={() => (viewing = null)} onsave={() => save(viewing.media)} />{/if}

<style>
  .placeholder { flex: 1; display: grid; place-content: center; gap: 10px; color: var(--text-3); text-align: center; }
  header {
    display: flex; align-items: center; gap: 10px; padding: 10px 16px; border-bottom: 1px solid var(--sidebar-border);
    background: color-mix(in srgb, var(--bg) 92%, var(--sidebar));
  }
  .title { min-width: 0; flex: 1; }
  .find-btn svg { width: 16px; height: 16px; }
  .find { display: flex; align-items: center; gap: 4px; }
  .find input {
    width: 190px; padding: 5px 9px; border-radius: 7px; border: 1px solid var(--field-border); background: var(--field);
    color: var(--text); outline: none; user-select: text;
  }
  .find input:focus { border-color: var(--blue); }
  .find .count { font-size: 11.5px; color: var(--text-2); min-width: 64px; text-align: right; }
  .find .icon-btn { font-size: 11px; }
  .name { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sub { font-size: 11.5px; color: var(--text-2); }
  .messages {
    flex: 1; min-height: 0; padding: 10px 14px 6px; display: flex; flex-direction: column-reverse;
    user-select: text; -webkit-user-select: text; overflow-anchor: none;
  }
  .content { display: flex; flex-direction: column; flex: none; }
  .state { color: var(--text-2); text-align: center; margin: 40px auto; }
  .state .err { color: var(--text-3); font-size: 12px; }
  .messages.drop { outline: 3px dashed var(--blue); outline-offset: -8px; }
  .sep { text-align: center; color: var(--text-2); font-size: 11.5px; margin: 14px 0 6px; font-weight: 500; user-select: none; }
  .typing {
    align-self: flex-start; background: var(--received); border-radius: 18px; padding: 11px 13px; display: flex; gap: 4px;
    margin: 4px 0 4px 5px;
  }
  .typing span { width: 7px; height: 7px; border-radius: 50%; background: var(--text-3); animation: blink 1.2s infinite; }
  .typing span:nth-child(2) { animation-delay: 0.2s }
  .typing span:nth-child(3) { animation-delay: 0.4s }
  @keyframes blink { 0%, 60%, 100% { opacity: 0.35 } 30% { opacity: 1 } }
  .menu {
    position: fixed; z-index: 40; background: var(--bg); border: 1px solid var(--sidebar-border); border-radius: 12px;
    box-shadow: var(--shadow); padding: 5px; display: flex; flex-direction: column; min-width: 210px;
  }
  .menu > button { border: none; background: none; text-align: left; padding: 6px 10px; border-radius: 6px; }
  .menu > button:hover { background: var(--blue); color: white; }
  .menu .danger { color: var(--danger); }
  .quick { display: flex; justify-content: space-between; padding: 2px 2px 6px; border-bottom: 1px solid var(--sidebar-border); margin-bottom: 4px; }
  .quick button { border: none; background: none; font-size: 20px; width: 32px; height: 32px; border-radius: 50%; padding: 0; }
  .quick button:hover { background: var(--hover); transform: scale(1.15); }
  .quick .more { font-size: 18px; color: var(--text-2); background: var(--hover); }
  .more-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 2px; padding: 2px 2px 6px; border-bottom: 1px solid var(--sidebar-border); margin-bottom: 4px; }
  .more-grid button { border: none; background: none; font-size: 19px; height: 32px; border-radius: 8px; padding: 0; }
  .more-grid button:hover { background: var(--hover); }
  .more-grid button.mine { background: color-mix(in srgb, var(--blue) 25%, transparent); }
  .quick button.mine { background: color-mix(in srgb, var(--blue) 25%, transparent); }
</style>
