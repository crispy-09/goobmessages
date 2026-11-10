<script>
  import { onMount } from 'svelte'
  import { api } from '../lib/api.js'
  import { select } from '../lib/state.svelte.js'

  let { onclose } = $props()
  let query = $state('')
  let recipients = $state([]) // { name, number, raw }
  let contacts = $state([])
  let contactsError = $state('')
  let busy = $state(false)
  let error = $state('')
  let input = $state()

  onMount(() => {
    input?.focus()
    api.contacts()
      .then((c) => (contacts = c ?? []))
      .catch((e) => (contactsError = String(e?.message ?? e)))
  })

  const digits = (s) => s.replace(/\D/g, '')
  const matches = $derived.by(() => {
    const q = query.trim().toLowerCase()
    if (!q) return contacts.slice(0, 50)
    const qd = digits(q)
    return contacts
      .filter((c) => c.name.toLowerCase().includes(q) || (qd.length >= 3 && digits(c.raw).includes(qd)))
      .slice(0, 50)
  })

  function add(c) {
    if (!recipients.some((r) => r.raw === c.raw)) recipients.push(c)
    query = ''
    input?.focus()
  }

  // Typed numbers become recipients on comma / Enter.
  function addTyped() {
    const parts = query.split(/[,;\n]/).map((s) => s.trim()).filter(Boolean)
    for (const p of parts) if (digits(p).length >= 3) add({ name: '', number: p, raw: p })
    query = ''
  }

  function onKey(e) {
    if (e.key === 'Enter') {
      e.preventDefault()
      if (query.trim()) {
        if (matches.length && !/^[+\d\s().-]+$/.test(query)) add(matches[0])
        else addTyped()
      } else if (recipients.length) start()
    } else if (e.key === ',' || e.key === ';') {
      e.preventDefault()
      addTyped()
    } else if (e.key === 'Backspace' && !query && recipients.length) {
      recipients.pop()
    }
  }

  async function start() {
    if (query.trim()) addTyped()
    if (!recipients.length) return
    busy = true
    error = ''
    try {
      const id = await api.startConversation(recipients.map((r) => r.raw))
      onclose()
      select(id)
    } catch (err) {
      error = String(err?.message ?? err)
    } finally {
      busy = false
    }
  }
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onclose()} />

<div class="sheet-backdrop" role="presentation" onclick={(e) => e.target === e.currentTarget && onclose()}>
  <div class="sheet" role="dialog" aria-modal="true" aria-labelledby="new-title">
    <h2 id="new-title">New Message</h2>
    <div class="to">
      <span class="label">To:</span>
      {#each recipients as r, i (r.raw)}
        <span class="chip">{r.name || r.number}<button aria-label="Remove {r.name || r.number}" onclick={() => recipients.splice(i, 1)}>×</button></span>
      {/each}
      <input
        bind:this={input}
        bind:value={query}
        onkeydown={onKey}
        placeholder={recipients.length ? '' : 'Name or phone number'}
        autocomplete="off"
        spellcheck="false"
      />
    </div>

    <div class="list scroll">
      {#if contactsError && !contacts.length}
        <p class="hint">Couldn't load contacts ({contactsError}). You can still type a number.</p>
      {:else if !contacts.length}
        <p class="hint">Loading contacts…</p>
      {:else if !matches.length}
        <p class="hint">No matching contacts. Press Enter to use “{query}” as a number.</p>
      {/if}
      {#each matches as c (c.name + c.raw)}
        <button class="contact" onclick={() => add(c)}>
          <span class="av" style="background:{/^#[0-9a-f]{3,8}$/i.test(c.color) ? c.color : '#8e8e93'}">{(c.name || '#').trim().charAt(0).toUpperCase()}</span>
          <span class="ctext"><span class="cname">{c.name || c.number}</span><span class="cnum">{c.number}</span></span>
        </button>
      {/each}
    </div>

    <p class="hint">Several recipients start a group conversation.</p>
    {#if error}<p class="err">{error}</p>{/if}
    <div class="actions">
      <button type="button" class="secondary" onclick={onclose}>Cancel</button>
      <button class="primary" disabled={busy || (!recipients.length && !query.trim())} onclick={start}>{busy ? 'Starting…' : 'Start'}</button>
    </div>
  </div>
</div>

<style>
  .to {
    display: flex; flex-wrap: wrap; gap: 5px; align-items: center; padding: 6px 8px; border-radius: 8px;
    border: 1px solid var(--field-border); background: var(--field);
  }
  .to:focus-within { border-color: var(--blue); }
  .label { font-size: 12px; color: var(--text-2); }
  .to input { flex: 1; min-width: 140px; border: none; background: transparent; outline: none; padding: 3px 2px; user-select: text; color: var(--text); }
  .chip { display: inline-flex; align-items: center; gap: 3px; background: var(--blue); color: white; border-radius: 12px; padding: 2px 4px 2px 9px; font-size: 13px; }
  .chip button { border: none; background: none; color: white; padding: 0 4px; font-size: 15px; line-height: 1; }
  .list { max-height: 280px; min-height: 120px; overflow-y: auto; margin: 8px -6px 0; }
  .contact { display: flex; gap: 10px; align-items: center; width: 100%; border: none; background: none; text-align: left; padding: 6px; border-radius: 8px; }
  .contact:hover { background: var(--hover); }
  .av { width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; color: white; font-weight: 600; font-size: 13px; flex: none; }
  .ctext { display: flex; flex-direction: column; min-width: 0; }
  .cname { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .cnum { font-size: 12px; color: var(--text-2); }
  .hint { color: var(--text-3); font-size: 12px; margin: 6px; }
  .err { color: var(--danger); font-size: 13px; }
  .actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 12px; }
</style>
