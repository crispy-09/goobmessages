<script>
  import { onMount } from 'svelte'
  import { api } from '../lib/api.js'
  import { fileSize } from '../lib/format.js'

  let { media, fromMe, local, onview } = $props()
  let el = $state()
  let url = $state('')
  let thumb = $state('')
  let failed = $state(false)
  let errorText = $state('')
  let loading = $state(false)

  const kind = $derived(
    media.mime?.startsWith('image/') ? 'image' : media.mime?.startsWith('video/') ? 'video' : media.mime?.startsWith('audio/') ? 'audio' : 'file'
  )
  const aspect = $derived(media.width > 0 && media.height > 0 ? `${media.width} / ${media.height}` : '4 / 3')

  async function load(full = true) {
    if (!media.id || loading || url) return
    loading = true
    try {
      if (!full && media.thumbId) thumb = await api.getMedia(media.thumbId, media.thumbKey, 'image/jpeg')
      else url = await api.getMedia(media.id, media.key, media.mime)
    } catch (e) {
      failed = true
      errorText = String(e?.message ?? e ?? '')
    } finally {
      loading = false
    }
  }

  // Images load when scrolled into view; videos show their thumbnail until played; files load on demand.
  onMount(() => {
    if (!media.id || (kind !== 'image' && kind !== 'video')) return
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        io.disconnect()
        load(kind === 'image')
      }
    }, { rootMargin: '400px' })
    io.observe(el)
    return () => io.disconnect()
  })

  function retry() {
    failed = false
    errorText = ''
    url = ''
    thumb = ''
    load(kind === 'image' || kind === 'audio' || !media.thumbId)
  }

  // The download worked but the webview couldn't show it (unsupported format, or the local media URL failed).
  function displayError() {
    failed = true
    errorText = `can't display this ${kind}`
  }

  async function playVideo() {
    await load(true)
  }
  async function playAudio() {
    await load(true)
  }
</script>

<div bind:this={el} class="media {kind}" class:me={fromMe}>
  {#if local}
    <div class="file pending"><span class="spinner"></span> Sending {media.name || 'attachment'}…</div>
  {:else if failed}
    <div class="file err" title={errorText}>
      <span>⚠️ Couldn't load {kind === 'file' ? media.name || 'attachment' : kind}{#if errorText}<small class="why">{errorText}</small>{/if}</span>
      <button class="retry" onclick={retry}>Retry</button>
    </div>
  {:else if kind === 'image'}
    {#if url}
      <button class="img-btn" onclick={() => onview({ url, mime: media.mime, name: media.name, media })}>
        <img src={url} alt={media.name || 'Image'} style="aspect-ratio:{aspect}" draggable="false" onerror={displayError} />
      </button>
    {:else}
      <div class="ph" style="aspect-ratio:{aspect}">{#if loading}<span class="spinner big"></span>{/if}</div>
    {/if}
  {:else if kind === 'video'}
    {#if url}
      <!-- svelte-ignore a11y_media_has_caption -->
      <video src={url} controls autoplay style="aspect-ratio:{aspect}" onerror={displayError}></video>
    {:else}
      <button class="ph video-ph" style="aspect-ratio:{aspect};{thumb ? `background-image:url(${thumb})` : ''}" onclick={playVideo} aria-label="Play video">
        <span class="play">{loading ? '…' : '▶'}</span>
      </button>
    {/if}
  {:else if kind === 'audio'}
    {#if url}
      <audio src={url} controls autoplay onerror={displayError}></audio>
    {:else}
      <button class="file" onclick={playAudio}>{loading ? 'Loading…' : '▶ Audio message'}</button>
    {/if}
  {:else}
    <button class="file" onclick={() => onview({ url: '', mime: media.mime, name: media.name, media, download: true })}>
      📎 <span class="fname">{media.name || 'Attachment'}</span> <small>{fileSize(media.size)}</small>
    </button>
  {/if}
</div>

<style>
  .media { margin: 0 5px; max-width: 100%; }
  .image, .video { width: min(300px, 100%); }
  img, video { display: block; width: 100%; height: auto; max-height: 420px; object-fit: cover; border-radius: 16px; background: var(--received); }
  .img-btn { border: none; padding: 0; background: none; display: block; width: 100%; cursor: zoom-in; }
  .ph { width: 100%; max-height: 420px; border-radius: 16px; background: var(--received); border: none; display: block; }
  .video-ph { background-size: cover; background-position: center; display: grid; place-items: center; }
  .play { width: 46px; height: 46px; border-radius: 50%; background: rgba(0, 0, 0, 0.5); color: white; display: grid; place-items: center; font-size: 18px; }
  audio { max-width: 280px; height: 40px; }
  .file {
    display: flex; align-items: center; gap: 6px; border: none; background: var(--received); color: var(--received-text);
    padding: 9px 13px; border-radius: 16px; max-width: 300px; text-align: left;
  }
  .me .file { background: linear-gradient(var(--blue-top), var(--blue)); color: white; }
  .fname { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .file small { opacity: 0.7; flex: none; }
  .pending { opacity: 0.75; }
  .ph { display: grid; place-items: center; }
  .err { flex-direction: row; align-items: center; justify-content: space-between; gap: 10px; }
  .err > span { display: flex; flex-direction: column; min-width: 0; }
  .why { opacity: 0.7; font-size: 11px; overflow-wrap: anywhere; }
  .retry { border: none; background: var(--blue); color: white; border-radius: 10px; padding: 3px 10px; font-size: 12px; flex: none; }
  .spinner.big { width: 20px; height: 20px; border-color: var(--text-3); border-top-color: transparent; }
  .spinner { width: 12px; height: 12px; border-radius: 50%; border: 2px solid currentColor; border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg) } }
</style>
