<script>
  import { onMount } from 'svelte'
  import { api } from '../lib/api.js'
  import { ui, avatarFor } from '../lib/state.svelte.js'
  import { initials, safeColor } from '../lib/format.js'

  let { conv, size = 40 } = $props()

  const av = $derived(avatarFor(conv))
  const bg = $derived(safeColor(conv?.color))

  // Avatars that loaded before the UI subscribed to events are fetched from the backend cache once.
  onMount(() => {
    if (!conv) return
    const keys = conv.hasGroupAvatar ? ['group:' + conv.id] : (conv.avatarIds ?? []).slice(0, 4)
    for (const k of keys) {
      if (ui.avatars[k] === undefined) {
        api.avatar(k).then((u) => { if (u) ui.avatars[k] = u }).catch(() => {})
      }
    }
  })
</script>

<div class="avatar" style="width:{size}px;height:{size}px;font-size:{Math.round(size * 0.38)}px">
  {#if av.url}
    <img src={av.url} alt="" draggable="false" />
  {:else if av.collage.length >= 2}
    <div class="collage" class:four={av.collage.length >= 3}>
      {#each av.collage as u}<img src={u} alt="" draggable="false" />{/each}
    </div>
  {:else if conv?.isGroup}
    <div class="initials group" style="background:linear-gradient(#a5a5ab,#86868b)">
      <svg viewBox="0 0 24 24" fill="white"><circle cx="9" cy="8" r="3.4"/><circle cx="16.5" cy="9" r="2.6"/><path d="M2.5 19c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6v.5h-13zM15.6 13.2c3.3-.4 6 1.6 6 5v.6h-4.6c0-2-.5-4-1.4-5.6z"/></svg>
    </div>
  {:else}
    <div class="initials" style="background:linear-gradient(color-mix(in srgb, {bg} 80%, white), {bg})">{initials(conv?.name)}</div>
  {/if}
</div>

<style>
  .avatar { border-radius: 50%; overflow: hidden; flex: none; }
  img { width: 100%; height: 100%; object-fit: cover; display: block; }
  .initials { width: 100%; height: 100%; display: grid; place-items: center; color: white; font-weight: 600; letter-spacing: 0.02em; }
  .group svg { width: 62%; height: 62%; }
  .collage { display: grid; grid-template-columns: 1fr 1fr; width: 100%; height: 100%; }
  .collage img { aspect-ratio: auto; }
  .collage:not(.four) img { height: 100%; }
  .collage.four { grid-template-rows: 1fr 1fr; }
</style>
