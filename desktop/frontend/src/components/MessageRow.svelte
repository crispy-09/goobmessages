<script>
  import { api } from '../lib/api.js'
  import { linkify, isEmojiOnly, firstWebLink } from '../lib/linkify.js'
  import { previews } from '../lib/previews.svelte.js'
  import LinkCard from './LinkCard.svelte'
  import { fileSize } from '../lib/format.js'
  import Media from './Media.svelte'

  let { row, isGroup, onmenu, onview, onreact, onjump, highlight = false, previewOK = false } = $props()
  const m = $derived(row.m)
  const segments = $derived(linkify(m.text))
  const bigEmoji = $derived(!m.media?.length && isEmojiOnly(m.text))
  // Link card: for the first web link; when the message is only that link, the loaded card replaces the bubble.
  const link = $derived(previewOK && !bigEmoji && !m.local ? firstWebLink(m.text) : null)
  const cardOnly = $derived(!!(link?.whole && !m.subject && previews[link.href]))
  const statusText = $derived(
    { sending: 'Sending…', sent: 'Sent', delivered: 'Delivered', read: 'Read', failed: 'Not Delivered' }[m.state] ?? ''
  )

  function click(e, href) {
    e.preventDefault()
    api.openLink(href)
  }
  function replySummary(r) {
    if (!r) return 'Original message'
    if (r.text) return r.text
    return r.media?.length ? 'Attachment' : 'Message'
  }
</script>

{#if m.tombstone}
  {#if m.text}<div class="tomb">{m.text}</div>{/if}
{:else}
  <div class="row" class:me={m.fromMe} class:tail={row.tail} class:grouped={isGroup && !m.fromMe} class:highlight data-mid={m.id}>
    {#if row.showName}<div class="sender">{m.senderName}</div>{/if}

    {#if m.replyToId}
      <div
        class="reply-ref"
        class:theirs={row.replyTo && !row.replyTo.fromMe}
        role="link"
        tabindex="0"
        onclick={() => onjump?.(m.replyToId)}
        onkeydown={(e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), onjump?.(m.replyToId))}
        title="Show the original message"
      >
        <span class="reply-text">{replySummary(row.replyTo)}</span>
      </div>
      <span class="reply-line" aria-hidden="true"></span>
    {/if}

    <div class="stack" oncontextmenu={onmenu} role="group">
      {#if m.reactions?.length}
        <div class="reactions">
          {#each m.reactions as r}
            <button class="reaction" class:mine={r.byMe} onclick={() => onreact(r.emoji)} title={r.byMe ? 'Remove' : 'React'}>
              {r.emoji}{#if r.count > 1}<small>{r.count}</small>{/if}
            </button>
          {/each}
        </div>
      {/if}

      {#each m.media ?? [] as md, i (md.id || i)}
        <Media media={md} fromMe={m.fromMe} local={m.local} {onview} />
      {/each}

      {#if m.subject}<div class="bubble subject"><b>{m.subject}</b></div>{/if}

      {#if bigEmoji}
        <div class="emoji">{m.text}</div>
      {:else if m.text && !cardOnly}
        <div class="bubble" class:failed={m.state === 'failed'}>
          {#each segments as s}{#if s.href}<a href={s.href} onclick={(e) => click(e, s.href)} title={s.href}>{s.text}</a>{:else}{s.text}{/if}{/each}
        </div>
      {:else if m.local && !m.media?.length}
        <div class="bubble">Attachment</div>
      {/if}
      {#if link}<LinkCard href={link.href} />{/if}
    </div>

    {#if m.fromMe && row.showStatus && statusText}
      <div class="status" class:err={m.state === 'failed'}>{statusText}</div>
    {/if}
  </div>
{/if}

<style>
  .row { display: flex; flex-direction: column; align-items: flex-start; margin-top: 2px; max-width: 100%; }
  .row.me { align-items: flex-end; }
  .row.tail { margin-bottom: 6px; }
  .sender { font-size: 11.5px; color: var(--text-2); margin: 6px 0 1px 18px; }
  .stack { display: flex; flex-direction: column; align-items: inherit; gap: 2px; max-width: min(72%, 560px); position: relative; }
  .row.me .stack { align-items: flex-end; }

  .bubble {
    position: relative; padding: 7px 12px 8px; border-radius: var(--radius); line-height: 1.35; font-size: 14px;
    white-space: pre-wrap; overflow-wrap: anywhere; word-break: break-word; background: var(--received); color: var(--received-text);
    margin: 0 5px; max-width: 100%; z-index: 0; /* stacking context: the tail paints under the text */
  }
  .me .bubble { background: linear-gradient(var(--blue-top), var(--blue)); background-attachment: fixed; color: white; }
  .bubble.subject { padding-bottom: 4px; }
  .bubble.failed { opacity: 0.6; }
  .bubble a { color: inherit; text-decoration: underline; text-underline-offset: 2px; cursor: pointer; }
  .row:not(.me) .bubble a { color: var(--blue); }

  /* iMessage-style tail on the last bubble of a run (two pseudo-elements carve the curve). */
  .tail .stack > .bubble:last-child::before,
  .tail .stack > .bubble:last-child::after { content: ''; position: absolute; bottom: 0; height: 20px; z-index: -1; }
  .tail .stack > .bubble:last-child::before { left: -7px; width: 20px; background: var(--received); border-bottom-right-radius: 16px 14px; }
  .tail .stack > .bubble:last-child::after { left: -10px; width: 10px; background: var(--bg); border-bottom-right-radius: 10px; }
  .me.tail .stack > .bubble:last-child::before { left: auto; right: -7px; background: inherit; border-bottom-right-radius: 0; border-bottom-left-radius: 16px 14px; }
  .me.tail .stack > .bubble:last-child::after { left: auto; right: -10px; border-bottom-right-radius: 0; border-bottom-left-radius: 10px; }

  .emoji { font-size: 40px; line-height: 1.15; margin: 0 4px; }
  .status { font-size: 11px; color: var(--text-2); margin: 2px 8px 2px; }
  .status.err { color: var(--danger); font-weight: 600; }
  .tomb { text-align: center; font-size: 11.5px; color: var(--text-2); margin: 8px 20px; }

  /* Reply reference: a small outlined copy of the original, like iMessage, joined to the reply by a short line. */
  .reply-ref {
    margin: 4px 10px 0; max-width: min(60%, 380px); padding: 5px 11px; border-radius: 15px; cursor: pointer;
    border: 1.5px solid var(--received); color: var(--text-2); background: transparent; outline: none;
  }
  .reply-ref.theirs { border-color: color-mix(in srgb, var(--received) 80%, var(--text-3)); }
  .reply-ref:hover { color: var(--text); border-color: var(--text-3); }
  .reply-ref:focus-visible { outline: 2px solid var(--blue); outline-offset: 1px; }
  .reply-line { width: 1.5px; height: 6px; background: var(--received); margin: 0 26px; }
  .row.highlight .stack > :global(*) { animation: flash 1.4s ease-out; }
  @keyframes flash { 0% { transform: scale(1); } 18% { transform: scale(1.06); } 40% { transform: scale(0.99); } 60%, 100% { transform: none; } }
  .reply-text { font-size: 12.5px; line-height: 1.3; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; white-space: pre-wrap; }

  .reactions { position: absolute; top: -14px; left: -6px; display: flex; gap: 2px; z-index: 2; }
  .me .reactions { left: auto; right: -6px; }
  .reaction {
    border: 2px solid var(--bg); background: var(--received); border-radius: 14px; padding: 1px 6px; font-size: 13px; line-height: 1.3;
  }
  .reaction.mine { background: var(--blue); }
  .reaction small { font-size: 10px; margin-left: 2px; }
  .stack:has(.reactions) { margin-top: 14px; }
</style>
