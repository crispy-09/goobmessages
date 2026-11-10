<script>
  import { onMount } from 'svelte'
  import { api } from '../lib/api.js'
  import { previews, loadPreview } from '../lib/previews.svelte.js'

  // href: the link as written in the message (opened on click). Renders nothing until a preview has loaded.
  let { href } = $props()
  let el = $state()
  const p = $derived(previews[href])

  // Fetch only when the row scrolls near the view, so opening a long chat doesn't fetch every link in it.
  onMount(() => {
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        io.disconnect()
        loadPreview(href)
      }
    }, { rootMargin: '600px' })
    io.observe(el)
    return () => io.disconnect()
  })

  function open(e) {
    e.preventDefault()
    api.openLink(href)
  }
</script>

<div bind:this={el} class="slot">
  {#if p}
    <a class="card" class:image-only={!p.title} {href} onclick={open} title={href}>
      {#if !p.title && p.image}
        <img class="big" src={p.image} alt="" draggable="false" />
      {:else}
        {#if p.image || p.icon}<img class="thumb" src={p.image || p.icon} alt="" draggable="false" />{/if}
        <span class="text">
          <span class="title">{p.title}</span>
          <span class="host">
            {#if p.image && p.icon}<img class="icon" src={p.icon} alt="" draggable="false" />{/if}
            {p.siteName && p.siteName.toLowerCase() !== p.host ? `${p.siteName} · ${p.host}` : p.host}
          </span>
        </span>
      {/if}
    </a>
  {/if}
</div>

<style>
  .slot { margin: 0 5px; min-height: 1px; }
  .card {
    display: flex; align-items: center; gap: 9px; width: 260px; max-width: 100%; padding: 7px; border-radius: 14px;
    background: color-mix(in srgb, var(--received) 85%, var(--text) 6%); color: var(--text); text-decoration: none;
    overflow: hidden; cursor: pointer;
  }
  .card:hover { filter: brightness(0.97); }
  .card.image-only { padding: 0; }
  .big { display: block; width: 100%; max-height: 180px; object-fit: cover; }
  .thumb { width: 52px; height: 52px; border-radius: 8px; object-fit: cover; flex: none; background: var(--bg); }
  .text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .title {
    font-size: 12.5px; font-weight: 600; line-height: 1.3; overflow: hidden; display: -webkit-box;
    -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow-wrap: anywhere;
  }
  .host { font-size: 11px; color: var(--text-2); display: flex; align-items: center; gap: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .icon { width: 12px; height: 12px; border-radius: 3px; flex: none; }
</style>
