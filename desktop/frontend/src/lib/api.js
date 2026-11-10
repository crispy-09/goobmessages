// Thin wrapper over the Wails bindings (window.go.main.App) and runtime (window.runtime).
// Views never talk to libgm directly; everything goes through the Go App.

const app = () => window.go?.main?.App
const rt = () => window.runtime

function call(name, ...args) {
  const a = app()
  if (!a || !a[name]) return Promise.reject(new Error('Backend not available'))
  return a[name](...args)
}

export const api = {
  status: () => call('GetStatus'),
  startPairing: () => call('StartPairing'),
  cancelPairing: () => call('CancelPairing'),
  logout: () => call('Logout'),
  quit: () => call('Quit'),
  useHere: () => call('UseHere'),
  conversations: () => call('Conversations'),
  openConversation: (id) => call('OpenConversation', id),
  loadOlder: (id) => call('LoadOlder', id),
  setViewing: (id, focused) => call('SetViewing', id, focused),
  markRead: (id) => call('MarkRead', id),
  sendText: (id, text, replyTo) => call('SendText', id, text, replyTo || ''),
  pickAndSendFiles: (id) => call('PickAndSendFiles', id),
  sendFiles: (id, paths) => call('SendFiles', id, paths),
  sendFileData: (id, name, mime, b64) => call('SendFileData', id, name, mime, b64),
  react: (cid, mid, emoji, remove) => call('React', cid, mid, emoji, !!remove),
  deleteMessage: (cid, mid) => call('DeleteMessage', cid, mid),
  getMedia: (id, key, mime) => call('GetMedia', id, key, mime),
  saveMedia: (id, key, name) => call('SaveMedia', id, key, name),
  openLink: (url) => call('OpenLink', url),
  linkPreview: (url) => call('LinkPreview', url),
  avatar: (key) => call('Avatar', key),
  setTyping: (id) => call('SetTyping', id),
  startConversation: (numbers) => call('StartConversation', numbers),
  hideAlerts: (id, hide) => call('HideAlerts', id, hide),
  setArchived: (id, archived) => call('SetArchived', id, !!archived),
  deleteConversation: (id) => call('DeleteConversation', id),
  contacts: () => call('Contacts'),
  getPrefs: () => call('GetPrefs'),
  version: () => call('Version'),
  setPrefs: (p) => call('SetPrefs', p),
}

export function on(event, cb) {
  const r = rt()
  if (!r) return () => {}
  return r.EventsOn(event, cb)
}

export function onFileDrop(cb) {
  const r = rt()
  if (!r?.OnFileDrop) return () => {}
  r.OnFileDrop((x, y, paths) => cb(paths), true)
  return () => r.OnFileDropOff?.()
}
