<script>
  let { item, onclose, onsave } = $props()
  function key(e) {
    if (e.key === 'Escape') onclose()
  }
</script>

<svelte:window onkeydown={key} />

<div class="viewer" role="dialog" aria-modal="true" aria-label="Attachment">
  <button class="backdrop" aria-label="Close" onclick={onclose}></button>
  <div class="bar">
    <span class="name">{item.name || (item.mime?.startsWith('image/') ? 'Image' : 'Attachment')}</span>
    <button class="secondary" onclick={onsave}>Save…</button>
    <button class="secondary" onclick={onclose}>Close</button>
  </div>
  {#if item.url && item.mime?.startsWith('image/')}
    <img src={item.url} alt={item.name || 'Image'} draggable="false" />
  {:else}
    <div class="file">
      <p>📎 {item.name || 'Attachment'}</p>
      <p class="hint">Save the file to open it with another app.</p>
      <button class="primary" onclick={onsave}>Save…</button>
    </div>
  {/if}
</div>

<style>
  .viewer { position: fixed; inset: 0; z-index: 70; display: grid; place-items: center; animation: fade 0.12s; }
  .backdrop { position: absolute; inset: 0; border: none; background: rgba(0, 0, 0, 0.82); cursor: zoom-out; }
  .bar { position: absolute; top: 12px; left: 16px; right: 16px; display: flex; gap: 8px; align-items: center; z-index: 1; }
  .bar .name { flex: 1; color: white; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .bar .secondary { background: rgba(255, 255, 255, 0.14); color: white; border-color: transparent; }
  img { position: relative; max-width: calc(100vw - 48px); max-height: calc(100vh - 96px); object-fit: contain; border-radius: 6px; }
  .file { position: relative; background: var(--bg); padding: 24px; border-radius: 14px; text-align: center; }
  .hint { color: var(--text-2); font-size: 12.5px; }
</style>
