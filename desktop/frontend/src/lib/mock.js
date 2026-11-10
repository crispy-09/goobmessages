// Development-only fake backend so the UI can be previewed in a plain browser (`npm run dev`, then open
// http://localhost:5173/?mock). Never bundled into production builds. All data is fictional.
const now = Date.now()
const min = 60000
const listeners = {}

const conversations = [
  { id: '1', name: 'Alex Rivera', preview: 'See you at 7! 🍕', timestamp: now - 3 * min, unread: true, color: '#ff9500', avatarIds: ['a'], isGroup: false, isRcs: true, participants: ['Alex Rivera'], contactIds: ['a'] },
  { id: '2', name: 'Weekend Hike', preview: 'Sam: I can bring snacks', timestamp: now - 50 * min, unread: false, color: '#34c759', avatarIds: ['b', 'c'], isGroup: true, isRcs: true, participants: ['Sam Lee', 'Jordan P'] },
  { id: '3', name: 'Mom', preview: 'Call me when you can ❤️', timestamp: now - 26 * 60 * min, unread: false, color: '#af52de', avatarIds: ['d'], isGroup: false, participants: ['Mom'], pinned: true },
  { id: '4', name: '+1 555-0100', preview: 'Your code is 123456', timestamp: now - 4 * 24 * 60 * min, color: '#8e8e93', avatarIds: ['e'], participants: [] },
  { id: '5', name: 'Taylor Brooks', preview: 'Thanks for the help yesterday, really appreciate it. Let me know if you need anything!', timestamp: now - 9 * 24 * 60 * min, color: '#007aff', avatarIds: ['f'], participants: ['Taylor Brooks'] },
]

const msg = (id, text, fromMe, ago, extra = {}) => ({
  id, tmpId: '', conversationId: '1', text, fromMe, timestamp: now - ago * min, state: fromMe ? 'read' : '',
  media: [], reactions: [], participantId: fromMe ? 'me' : 'a', senderName: 'Alex', ...extra,
})

const messages = {
  '1': [
    msg('m1', 'Hey! Are we still on for dinner tonight?', false, 95),
    msg('m2', 'Yes! Where do you want to go?', true, 93),
    msg('m3', 'How about that new pizza place on 5th?', false, 92),
    msg('m4', 'https://example.com/menu looks good', false, 91),
    msg('m5', 'Perfect 👍', true, 20, { reactions: [{ emoji: '❤️', count: 1, byMe: false }] }),
    msg('m6', '😂', false, 5, { replyToId: 'm3' }),
    msg('m6b', 'example.com/menu', true, 4),
    msg('m6c', '', false, 4, { media: [{ id: 'p1', key: 'AA==', mime: 'image/jpeg', width: 400, height: 300 }] }),
    msg('m6d', 'Did you get my reply?', true, 4, { replyToId: 'm2' }),
    msg('m6e', '', false, 4, { media: [{ id: 'bad', key: 'AA==', mime: 'image/jpeg', width: 400, height: 300 }] }),
    msg('m7', 'See you at 7! 🍕', false, 3),
    msg('m8', 'On my way, running maybe ten minutes late because of traffic on the bridge', true, 1, { state: 'delivered' }),
  ],
  '2': [
    { ...msg('g1', 'Who is in for Saturday?', false, 70), conversationId: '2', participantId: 'b', senderName: 'Sam Lee' },
    { ...msg('g2', 'Me!', false, 69), conversationId: '2', participantId: 'c', senderName: 'Jordan P' },
    { ...msg('g3', 'Count me in', true, 60), conversationId: '2' },
    { ...msg('g4', 'I can bring snacks', false, 50), conversationId: '2', participantId: 'b', senderName: 'Sam Lee' },
  ],
}

// ?long: a long conversation to check scrolling.
if (new URLSearchParams(location.search).has('long')) {
  for (let i = 0; i < 60; i++) messages['1'].unshift(msg('old' + i, `Older message number ${60 - i} with some text to wrap around a bit`, i % 3 === 0, 200 + i * 7))
}

const App = {
  GetStatus: async () => ({ phase: new URLSearchParams(location.search).has('login') ? 'login' : 'ready', banner: '', unread: 1 }),
  GetPrefs: async () => ({ notifications: true, previews: true, keepRunning: true, enterToSend: true, hiddenAlerts: {} }),
  SetPrefs: async () => {},
  Conversations: async () => conversations,
  OpenConversation: async (id) => messages[id] ?? [],
  LoadOlder: async () => false,
  SetViewing: async () => {},
  MarkRead: async () => {},
  SendText: async (cid, text, replyTo) => {
    ;(window.__calls ??= []).push(['SendText', cid, text, replyTo])
    const list = (messages[cid] ??= [])
    list.push({ ...msg('t' + Date.now(), text, true, 0), conversationId: cid, state: 'sending', local: true })
    listeners.messages?.forEach((f) => f({ conversationId: cid, messages: [...list] }))
  },
  StartPairing: async () => {
    const step = new URLSearchParams(location.search).get('step') || 'emoji'
    setTimeout(() => listeners.signin?.forEach((f) => f({ step, emoji: '🦊', error: 'The wrong emoji was tapped on the phone. Try again.' })), 300)
  },
  LinkPreview: async (url) => {
    ;(window.__calls ??= []).push(['LinkPreview', url])
    await new Promise((r) => setTimeout(r, 150))
    return url.includes('example.com') ? { url, title: 'Tony’s Pizza on 5th — Menu', siteName: 'Example', host: 'example.com', image: '', icon: '' } : null
  },
  GetMedia: async (id) => id === 'bad' ? Promise.reject('download failed (HTTP 404)') : 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="400" height="300"><rect width="400" height="300" fill="#7ab"/></svg>'),
  Contacts: async () => [
    { name: 'Alex Rivera', number: '(555) 010-1234', raw: '+15550101234', color: '#ff9500' },
    { name: 'Jordan P', number: '(555) 010-2222', raw: '+15550102222', color: '#34c759' },
    { name: 'Sam Lee', number: '(555) 010-3333', raw: '+15550103333', color: '#5856d6' },
  ],
  StartConversation: async (nums) => { ;(window.__calls ??= []).push(['StartConversation', nums]); return '1' },
  SetArchived: async (id, a) => { ;(window.__calls ??= []).push(['SetArchived', id, a]) },
  DeleteConversation: async (id) => { ;(window.__calls ??= []).push(['DeleteConversation', id]) },
  React: async (cid, mid, emoji, remove) => {
    ;(window.__calls ??= []).push(['React', cid, mid, emoji, remove])
  },
  CancelPairing: async () => {},
  Avatar: async () => '',
  SetTyping: async () => {},
}

export function installMock() {
  window.go = { main: { App: new Proxy(App, { get: (t, k) => t[k] ?? (async () => null) }) } }
  window.runtime = {
    EventsOn: (name, cb) => {
      ;(listeners[name] ??= []).push(cb)
      return () => (listeners[name] = listeners[name].filter((f) => f !== cb))
    },
  }
  const chat = new URLSearchParams(location.search).get('chat')
  const step = new URLSearchParams(location.search).get('step')
  if (step) setTimeout(() => listeners.signin?.forEach((f) => f({ step, emoji: '🦊', error: 'The wrong emoji was tapped on the phone. Try again.' })), 400)
  if (chat) setTimeout(() => listeners['open-conversation']?.forEach((f) => f(chat)), 400)
}
