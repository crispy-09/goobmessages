import { test } from 'node:test'
import assert from 'node:assert/strict'
import { linkify, isEmojiOnly } from './linkify.js'

const links = (t) => linkify(t).filter((s) => s.href).map((s) => s.href)

test('plain text stays text', () => {
  assert.deepEqual(linkify('hello there'), [{ text: 'hello there' }])
})

test('http and www links', () => {
  assert.deepEqual(links('see https://example.com/a?b=1.'), ['https://example.com/a?b=1'])
  assert.deepEqual(links('go to www.example.com, ok'), ['https://www.example.com/'])
})

test('balanced parens are kept', () => {
  assert.deepEqual(links('(https://en.wikipedia.org/wiki/Foo_(bar))'), ['https://en.wikipedia.org/wiki/Foo_(bar)'])
})

test('dangerous schemes are never links', () => {
  for (const t of ['javascript:alert(1)', 'file:///etc/passwd', 'data:text/html,<b>x</b>', 'vbscript:x']) {
    assert.deepEqual(links(t), [], t)
  }
  assert.deepEqual(links('https://user:pw@evil.example/'), [])
})

test('email and phone', () => {
  assert.deepEqual(links('mail a@b.co now'), ['mailto:a@b.co'])
  assert.deepEqual(links('call +1 (555) 555-0100'), ['tel:+15555550100'])
})

test('segments reassemble to the original text', () => {
  const t = 'a https://x.io b www.y.com c'
  assert.equal(linkify(t).map((s) => s.text).join(''), t)
})

test('emoji only', () => {
  assert.equal(isEmojiOnly('😂'), true)
  assert.equal(isEmojiOnly('👍🏽👍'), true)
  assert.equal(isEmojiOnly('hi 😂'), false)
  assert.equal(isEmojiOnly('123'), false)
  assert.equal(isEmojiOnly('😂😂😂😂'), false)
})

test('bare domains are links (like NSDataDetector)', () => {
  assert.deepEqual(links('try example.com/menu tonight'), ['https://example.com/menu'])
  assert.deepEqual(links('it is on google.com.'), ['https://google.com/'])
  assert.deepEqual(links('see bbc.co.uk'), ['https://bbc.co.uk/'])
  assert.deepEqual(links('medium.com/@writer'), ['https://medium.com/@writer'])
  assert.deepEqual(links('open file.txt or node.js or 1.5x'), [])
  assert.deepEqual(links('mail a@example.com'), ['mailto:a@example.com'])
})

test('firstWebLink', async () => {
  const { firstWebLink } = await import('./linkify.js')
  assert.deepEqual(firstWebLink(' https://example.com/x '), { href: 'https://example.com/x', whole: true })
  assert.deepEqual(firstWebLink('look example.com'), { href: 'https://example.com/', whole: false })
  assert.equal(firstWebLink('mail a@b.co'), null)
})
