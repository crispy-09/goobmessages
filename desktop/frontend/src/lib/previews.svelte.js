// Link-card cache for the UI. The Go side does the (guarded) fetching and its own caching; this only remembers
// results so rows re-rendering don't call the backend again.
import { api } from './api.js'

export const previews = $state({}) // href -> preview object | null (none)
const pending = new Set()

export function loadPreview(href) {
  if (!href || href in previews || pending.has(href)) return
  pending.add(href)
  api.linkPreview(href)
    .then((p) => { previews[href] = p && (p.title || p.image) ? p : null })
    .catch(() => { previews[href] = null })
    .finally(() => pending.delete(href))
}

// Links you sent always preview (unless off); otherwise per the setting, like the Mac app.
export function previewAllowed(mode, m, conv) {
  if (mode === 'off') return false
  if (mode === 'everyone' || m.fromMe) return true
  return !!(m.senderIsContact || conv?.contactIds?.includes(m.participantId))
}
