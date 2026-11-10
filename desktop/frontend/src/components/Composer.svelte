<script>
  import { tick } from 'svelte'
  import { api } from '../lib/api.js'
  import { ui, toast } from '../lib/state.svelte.js'
  import { fileToBase64 } from '../lib/format.js'

  let { conv, replyTo = $bindable(null), replyMessage = null } = $props()

  // Drafts are kept in memory per conversation (nothing is written to disk).
  const drafts = {}
  let text = $state('')
  let input = $state()
  let currentId = ''

  $effect(() => {
    const id = conv?.id ?? ''
    if (id !== currentId) {
      if (currentId) drafts[currentId] = text
      currentId = id
      text = drafts[id] ?? ''
      tick().then(() => { resize(); input?.focus() })
    }
  })

  // Choosing "Reply" puts the cursor in the composer.
  $effect(() => {
    if (replyTo) tick().then(() => input?.focus())
  })

  function resize() {
    if (!input) return
    input.style.height = 'auto'
    input.style.height = Math.min(input.scrollHeight, 160) + 'px'
  }

  async function send() {
    const body = text
    if (!body.trim() || !conv) return
    const reply = replyTo
    text = ''
    replyTo = null
    drafts[conv.id] = ''
    await tick()
    resize()
    try {
      await api.sendText(conv.id, body, reply || '')
    } catch (e) {
      toast(e)
    }
  }

  function onKey(e) {
    const enterSends = ui.prefs.enterToSend
    if (e.key === 'Enter' && !e.isComposing) {
      if ((enterSends && !e.shiftKey) || (!enterSends && (e.ctrlKey || e.metaKey))) {
        e.preventDefault()
        send()
      }
    } else if (e.key === 'Escape' && replyTo) {
      replyTo = null
    }
  }

  function onInput() {
    resize()
    if (conv && text) api.setTyping(conv.id)
  }

  async function onPaste(e) {
    const files = [...(e.clipboardData?.files ?? [])]
    if (!files.length || !conv) return
    e.preventDefault()
    for (const f of files) {
      if (f.size > 100 * 1024 * 1024) { toast(`${f.name} is too large (100 MB max)`); continue }
      try {
        const b64 = await fileToBase64(f)
        await api.sendFileData(conv.id, f.name || 'pasted', f.type || '', b64)
      } catch (err) { toast(err) }
    }
  }

  async function attach() {
    try { await api.pickAndSendFiles(conv.id) } catch (e) { toast(e) }
  }
</script>

{#if conv?.readOnly}
  <div class="readonly">You can't reply to this conversation.</div>
{:else}
  <div class="composer">
    {#if replyTo}
      <div class="reply">
        <span class="bar"></span>
        <span class="rtext">Replying to: {replyMessage?.text || (replyMessage?.media?.length ? 'Attachment' : 'message')}</span>
        <button class="icon-btn" aria-label="Cancel reply" onclick={() => (replyTo = null)}>✕</button>
      </div>
    {/if}
    <div class="row">
      <button class="icon-btn attach" title="Attach files" aria-label="Attach files" onclick={attach}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M21 11.5 12.5 20a5.5 5.5 0 0 1-7.8-7.8l8.6-8.6a3.7 3.7 0 0 1 5.2 5.2l-8.6 8.6a1.8 1.8 0 0 1-2.6-2.6l7.9-7.9"/></svg>
      </button>
      <div class="field">
        <textarea
          bind:this={input}
          bind:value={text}
          rows="1"
          placeholder={conv?.isRcs ? 'RCS message' : 'Text message'}
          onkeydown={onKey}
          oninput={onInput}
          onpaste={onPaste}
          spellcheck="true"
        ></textarea>
        {#if text.trim()}
          <button class="send" aria-label="Send" title="Send" onclick={send}>
            <svg viewBox="0 0 24 24"><path d="M12 19V6M6.5 11.5 12 6l5.5 5.5" fill="none" stroke="white" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
          </button>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .composer { padding: 6px 12px 12px; }
  .readonly { padding: 14px; text-align: center; color: var(--text-2); font-size: 12.5px; }
  .row { display: flex; align-items: flex-end; gap: 6px; }
  .attach { margin-bottom: 2px; }
  .field {
    flex: 1; display: flex; align-items: flex-end; border: 1px solid var(--field-border); border-radius: 18px;
    background: var(--field); padding: 3px 3px 3px 12px; min-height: 34px;
  }
  textarea {
    flex: 1; border: none; outline: none; resize: none; background: transparent; line-height: 20px; padding: 4px 0;
    max-height: 160px; overflow-y: auto; user-select: text; -webkit-user-select: text;
  }
  textarea::placeholder { color: var(--text-3); }
  .send { width: 27px; height: 27px; border-radius: 50%; border: none; background: var(--blue); display: grid; place-items: center; padding: 0; flex: none; }
  .send svg { width: 17px; height: 17px; }
  .reply { display: flex; align-items: center; gap: 8px; margin: 0 0 6px 40px; font-size: 12.5px; color: var(--text-2); }
  .bar { width: 3px; align-self: stretch; background: var(--blue); border-radius: 2px; }
  .rtext { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
</style>
