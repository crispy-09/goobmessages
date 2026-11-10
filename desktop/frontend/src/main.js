import { mount } from 'svelte'
import './style.css'
import App from './App.svelte'

async function start() {
  // Dev-only browser preview with fake data: http://localhost:5173/?mock
  if (import.meta.env.DEV && !window.go && new URLSearchParams(location.search).has('mock')) {
    const { installMock } = await import('./lib/mock.js')
    installMock()
  }
  mount(App, { target: document.getElementById('app') })
}
start()
