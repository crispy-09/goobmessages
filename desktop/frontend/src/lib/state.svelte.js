import { api, on } from './api.js'

// Mirror of backend ui. The Go App is authoritative; it pushes changes as events.
export const ui = $state({
  status: { phase: 'loading', banner: '', error: '', unread: 0, inactive: false },
  conversations: [],
  messages: {}, // conversationId -> Message[]
  hasMore: {}, // conversationId -> bool
  loadState: {}, // conversationId -> 'loading' | 'error'
  loadError: {},
  selectedId: '',
  avatars: {}, // key -> data URL
  typing: {}, // conversationId -> expiry ms
  prefs: { notifications: true, previews: true, keepRunning: true, enterToSend: true, hiddenAlerts: {} },
  showArchived: false,
  search: '',
  toast: '',
  focused: document.hasFocus(),
})

let toastTimer
export function toast(msg) {
  ui.toast = String(msg?.message ?? msg ?? '')
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (ui.toast = ''), 5000)
}

export async function init() {
  on('status', (s) => (ui.status = s))
  on('conversations', (list) => (ui.conversations = list ?? []))
  on('messages', ({ conversationId, messages }) => (ui.messages[conversationId] = messages ?? []))
  on('avatar', ({ key, url }) => (ui.avatars[key] = url))
  on('typing', ({ conversationId, typing }) => {
    if (typing) ui.typing[conversationId] = Date.now() + 8000
    else delete ui.typing[conversationId]
  })
  on('open-conversation', (id) => select(id))
  // Typing indicators expire if the "stopped typing" event never arrives.
  setInterval(() => {
    const now = Date.now()
    for (const [id, until] of Object.entries(ui.typing)) if (until <= now) delete ui.typing[id]
  }, 2000)

  window.addEventListener('focus', () => {
    ui.focused = true
    syncViewing()
  })
  window.addEventListener('blur', () => {
    ui.focused = false
    syncViewing()
  })
  document.addEventListener('visibilitychange', syncViewing)

  try {
    ui.status = await api.status()
    ui.prefs = await api.getPrefs()
    ui.conversations = (await api.conversations()) ?? []
  } catch (e) {
    console.warn(e)
  }
}

function syncViewing() {
  const focused = ui.focused && document.visibilityState === 'visible'
  api.setViewing(ui.selectedId, focused).catch(() => {})
}

export async function select(id) {
  if (!id) {
    ui.selectedId = ''
    syncViewing()
    return
  }
  ui.selectedId = id
  syncViewing()
  if (!ui.messages[id] && ui.loadState[id] !== 'loading') await retryLoad(id)
}

export async function retryLoad(id) {
  ui.loadState[id] = 'loading'
  try {
    const msgs = (await api.openConversation(id)) ?? []
    // The backend may already have pushed a newer list through the "messages" event.
    if (!ui.messages[id]?.length) ui.messages[id] = msgs
    ui.hasMore[id] = msgs.length > 0
    delete ui.loadState[id]
  } catch (e) {
    ui.loadState[id] = 'error'
    ui.loadError[id] = String(e?.message ?? e)
  }
}

export async function loadOlder(id) {
  if (ui.hasMore[id] === false) return false
  try {
    const more = await api.loadOlder(id)
    ui.hasMore[id] = more
    return more
  } catch (e) {
    toast(e)
    return false
  }
}

export async function savePrefs(p) {
  ui.prefs = p
  try {
    await api.setPrefs($state.snapshot(p))
  } catch (e) {
    toast(e)
  }
}

export function avatarFor(conv) {
  if (!conv) return { url: '', collage: [] }
  if (conv.hasGroupAvatar && ui.avatars['group:' + conv.id]) return { url: ui.avatars['group:' + conv.id], collage: [] }
  const urls = (conv.avatarIds ?? []).map((id) => ui.avatars[id]).filter(Boolean)
  if (!conv.isGroup) return { url: urls[0] ?? '', collage: [] }
  return { url: '', collage: urls.slice(0, 4) }
}
