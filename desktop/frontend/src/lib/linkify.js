// Splits untrusted message text into plain-text and link segments. The result is rendered as text nodes and
// <a> elements by Svelte (never as HTML). Only http(s), mailto and tel are linkified; the Go side re-checks
// the scheme before opening anything.

// Bare domains ("example.com/menu") are linked like NSDataDetector does on the Mac, limited to common TLDs so
// things like "file.txt" or "node.js" stay plain text.
const TLDS = 'com|org|net|edu|gov|mil|int|io|co|dev|app|me|us|uk|ca|de|fr|ly|gg|tv|ai|info|biz|xyz|so|to|be|nl|au|in|jp|it|es|ru|br|ch|se|no|fi|dk|pl|eu|nz|ie|at|mx|link|page|site|blog|news|shop|store|online|tech|cloud|gle|fm|im'
const DOMAIN = `(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+(?:${TLDS})`
const URL_RE = new RegExp(
  `\\b(?:https?:\\/\\/|www\\.)[^\\s<>"'\`]+|\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b|\\b${DOMAIN}\\b(?![@-]|\\.\\w)(?:[/?#][^\\s<>"'\`]*)?|(?:\\+?\\d[\\d\\s().-]{7,}\\d)`,
  'gi'
)
const BARE_DOMAIN = new RegExp(`^${DOMAIN}(?:[/?#]|$)`, 'i')
const EMAIL = /^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$/i
const TRAILING = /[.,;:!?)\]}'"]+$/

export function linkify(text) {
  const out = []
  if (!text) return out
  let last = 0
  for (const m of text.matchAll(URL_RE)) {
    let raw = m[0]
    let start = m.index
    // Keep balanced closing parens (e.g. Wikipedia links) but drop trailing punctuation.
    let trail = raw.match(TRAILING)?.[0] ?? ''
    if (trail.startsWith(')') && (raw.match(/\(/g)?.length ?? 0) > (raw.slice(0, -trail.length).match(/\)/g)?.length ?? 0)) {
      trail = trail.slice(1)
    }
    if (trail) raw = raw.slice(0, -trail.length)
    if (!raw) continue
    const href = toHref(raw)
    if (!href) continue
    if (start > last) out.push({ text: text.slice(last, start) })
    out.push({ text: raw, href })
    last = start + raw.length
  }
  if (last < text.length) out.push({ text: text.slice(last) })
  return out
}

export function toHref(raw) {
  if (/^https?:\/\//i.test(raw)) return safe(raw)
  if (/^www\./i.test(raw)) return safe('https://' + raw)
  if (EMAIL.test(raw)) return safe('mailto:' + raw)
  if (BARE_DOMAIN.test(raw)) return safe('https://' + raw)
  const digits = raw.replace(/[^\d+]/g, '')
  if (digits.replace('+', '').length >= 7 && digits.length <= 16) return 'tel:' + digits
  return null
}

function safe(u) {
  try {
    const url = new URL(u)
    if (!['http:', 'https:', 'mailto:'].includes(url.protocol)) return null
    if (url.username || url.password) return null
    return url.href
  } catch {
    return null
  }
}

// The first web link in the text, and whether the message is nothing but that link (then the card replaces the
// bubble, like iMessage).
export function firstWebLink(text) {
  const segs = linkify(text)
  const link = segs.find((s) => s.href && /^https?:/i.test(s.href))
  if (!link) return null
  return { href: link.href, whole: link.text.trim() === text.trim() }
}

// Returns true when the text is only 1–3 emoji (shown large, without a bubble).
export function isEmojiOnly(text) {
  if (!text || text.length > 24) return false
  const t = text.replace(/\s/g, '')
  if (!t) return false
  const seg = typeof Intl !== 'undefined' && Intl.Segmenter ? [...new Intl.Segmenter().segment(t)] : [...t]
  if (seg.length > 3) return false
  return /^(?:\p{Extended_Pictographic}|\p{Emoji_Component}|‍|️)+$/u.test(t) && !/^[\d#*]+$/.test(t)
}
