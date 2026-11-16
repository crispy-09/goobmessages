<script>
  import { onMount } from 'svelte'
  import { api } from '../lib/api.js'
  import { toast } from '../lib/state.svelte.js'
  import { fileSize } from '../lib/format.js'

  let { media, fromMe, local, onview } = $props()
  let el = $state()
  let url = $state('')
  let thumb = $state('')
  let failed = $state(false)
  let errorText = $state('')
  let loading = $state(false)
  let unplayable = $state(false) // downloaded, but the webview can't play it: offer to save it instead
  let saving = $state(false)

  const kind = $derived(
    media.mime?.startsWith('image/') ? 'image' : media.mime?.startsWith('video/') ? 'video' : media.mime?.startsWith('audio/') ? 'audio' : 'file'
  )
  const aspect = $derived(media.width > 0 && media.height > 0 ? `${media.width} / ${media.height}` : '4 / 3')

  // WebKitGTK's media player (GStreamer) only plays http(s), blob: and a few other URL schemes, not the app's own
  // wails:// scheme that serves attachments on Linux, so video/audio are handed to it as a blob: URL instead.
  // Images (and Windows, where the app is served over http) use the media URL directly.
  const needsBlob = !/^https?:$/.test(location.protocol)
  let blobUrl = ''

  async function playableUrl(src) {
    if (!needsBlob || kind === 'image') return src
    const res = await fetch(src)
    if (!res.ok) throw new Error(`couldn't read the ${kind} (${res.status})`)
    const blob = await res.blob()
    revokeBlob()
    blobUrl = URL.createObjectURL(blob.type ? blob : new Blob([blob], { type: media.mime }))
    return blobUrl
  }

  function revokeBlob() {
    if (blobUrl) URL.revokeObjectURL(blobUrl)
    blobUrl = ''
  }

  async function load(full = true) {
    if (!media.id || loading || url) return
    loading = true
    try {
      if (!full && media.thumbId) thumb = await api.getMedia(media.thumbId, media.thumbKey, 'image/jpeg')
      else url = await playableUrl(await api.getMedia(media.id, media.key, media.mime))
    } catch (e) {
      failed = true
      errorText = String(e?.message ?? e ?? '')
    } finally {
      loading = false
    }
  }

  // Images load when scrolled into view; videos show their thumbnail until played; files load on demand.
  onMount(() => {
    if (!media.id || (kind !== 'image' && kind !== 'video')) return revokeBlob
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        io.disconnect()
        load(kind === 'image')
      }
    }, { rootMargin: '400px' })
    io.observe(el)
    return () => {
      io.disconnect()
      revokeBlob()
    }
  })

  function retry() {
    failed = false
    errorText = ''
    url = ''
    thumb = ''
    revokeBlob()
    load(kind === 'image' || kind === 'audio' || !media.thumbId)
  }

  // The download worked but the webview couldn't show it (unsupported format, or the local media URL failed).
  // Videos/audio the webview can't play (codec, or a file Google Messages itself won't preview) become a download
  // card, like Messages for web does.
  function displayError() {
    if (kind === 'video' || kind === 'audio') {
      unplayable = true
      url = ''
      revokeBlob()
      return
    }
    failed = true
    errorText = `can't display this ${kind}`
  }

  // A broken file can also leave the player stuck on its first frame without an error event: if playback hasn't
  // advanced 10 s after loading (and the user didn't pause it), treat it as unplayable.
  let stallTimer
  function watchStall() {
    clearTimeout(stallTimer)
    stallTimer = setTimeout(displayError, 10000)
  }
  function progressed(e) {
    if (e.currentTarget.currentTime > 0.5) clearTimeout(stallTimer)
  }
  $effect(() => () => clearTimeout(stallTimer))

  async function save() {
    if (saving) return
    saving = true
    try {
      await api.saveMedia(media.id, media.key, media.name || (kind === 'video' ? 'video.mp4' : 'audio'))
    } catch (e) {
      toast(e)
    } finally {
      saving = false
    }
  }

  async function playVideo() {
    await load(true)
  }
  async function playAudio() {
    await load(true)
  }
</script>

{#snippet saveBtn()}
  <button class="dl" onclick={save} disabled={saving} title="Save video…" aria-label="Save video">
    {#if saving}<span class="spinner"></span>{:else}<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11"/><path d="m7 10 5 5 5-5"/><path d="M5 20h14"/></svg>{/if}
  </button>
{/snippet}

<div bind:this={el} class="media {kind}" class:me={fromMe}>
  {#if local}
    <div class="file pending"><span class="spinner"></span> Sending {media.name || 'attachment'}…</div>
  {:else if unplayable}
    <div class="file err">
      <span><span class="fname">{kind === 'video' ? '🎬' : '🎵'} {media.name || (kind === 'video' ? 'Video' : 'Audio message')}</span>
        <small class="why">Can't play here{media.size ? ` · ${fileSize(media.size)}` : ''}</small></span>
      <button class="retry" onclick={save} disabled={saving}>{saving ? 'Saving…' : 'Save…'}</button>
    </div>
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
      <div class="vwrap">
        <!-- svelte-ignore a11y_media_has_caption -->
        <video src={url} controls autoplay style="aspect-ratio:{aspect}" onerror={displayError} onloadstart={watchStall}
          ontimeupdate={progressed} onpause={() => clearTimeout(stallTimer)}></video>
        {@render saveBtn()}
      </div>
    {:else}
      <div class="vwrap">
        <button class="ph video-ph" style="aspect-ratio:{aspect};{thumb ? `background-image:url(${thumb})` : ''}" onclick={playVideo} aria-label="Play video">
          <span class="play">{loading ? '…' : '▶'}</span>
        </button>
        {@render saveBtn()}
      </div>
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
  .vwrap { position: relative; }
  .dl {
    position: absolute; top: 8px; left: 50%; transform: translateX(-50%); width: 32px; height: 32px; border-radius: 50%; border: none; padding: 0;
    background: rgba(0, 0, 0, 0.55); color: white; display: grid; place-items: center; cursor: pointer;
  }
  .dl:hover { background: rgba(0, 0, 0, 0.75); }
  .dl svg { width: 16px; height: 16px; }
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
