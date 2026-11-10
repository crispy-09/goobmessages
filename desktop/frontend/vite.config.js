import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'

// Dev-only: `?mock&shot` holds the page's load event ~1.5 s so headless screenshot tools capture the
// rendered mock UI rather than the first paint.
const screenshotDelay = {
  name: 'screenshot-delay',
  apply: 'serve',
  configureServer(server) {
    server.middlewares.use('/__shot_delay', (req, res) => {
      setTimeout(() => { res.setHeader('Content-Type', 'image/gif'); res.end(Buffer.from('R0lGODlhAQABAAAAACw=', 'base64')) }, 1500)
    })
  },
  transformIndexHtml(html, ctx) {
    if (!ctx.originalUrl?.includes('shot')) return html
    return html.replace('</body>', '<img src="/__shot_delay" alt="" hidden></body>')
  },
}

export default defineConfig({
  plugins: [svelte(), screenshotDelay],
  build: { outDir: 'dist', emptyOutDir: true, chunkSizeWarningLimit: 1500 },
})
