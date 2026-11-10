const DAY = 86400000

function startOfDay(ts) {
  const d = new Date(ts)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

// Sidebar timestamp: time today, "Yesterday", weekday this week, else short date.
export function listTime(ts, now = Date.now()) {
  if (!ts) return ''
  const today = startOfDay(now)
  if (ts >= today) return new Date(ts).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
  if (ts >= today - DAY) return 'Yesterday'
  if (ts >= today - 6 * DAY) return new Date(ts).toLocaleDateString([], { weekday: 'long' })
  return new Date(ts).toLocaleDateString([], { day: 'numeric', month: 'numeric', year: '2-digit' })
}

// Centered separator above a run of messages.
export function separatorTime(ts, now = Date.now()) {
  const time = new Date(ts).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })
  const today = startOfDay(now)
  if (ts >= today) return 'Today ' + time
  if (ts >= today - DAY) return 'Yesterday ' + time
  if (ts >= today - 6 * DAY) return new Date(ts).toLocaleDateString([], { weekday: 'long' }) + ' ' + time
  return new Date(ts).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' }) + ' at ' + time
}

export function initials(name) {
  const parts = (name || '').trim().split(/\s+/).filter((p) => /\p{L}/u.test(p[0] ?? ''))
  const s = parts.slice(0, 2).map((p) => [...p][0]).join('').toUpperCase()
  return s || '#'
}

export function safeColor(hex) {
  const h = (hex || '').replace('#', '')
  if (/^[0-9a-f]{6}$/i.test(h)) return '#' + h
  if (/^[0-9a-f]{8}$/i.test(h)) return '#' + h.slice(2)
  return '#8e8e93'
}

export function fileSize(n) {
  if (!n) return ''
  if (n < 1024) return n + ' B'
  if (n < 1024 * 1024) return (n / 1024).toFixed(0) + ' KB'
  return (n / 1024 / 1024).toFixed(1) + ' MB'
}

export function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const r = new FileReader()
    r.onload = () => resolve(String(r.result).split(',', 2)[1] ?? '')
    r.onerror = () => reject(r.error)
    r.readAsDataURL(file)
  })
}
