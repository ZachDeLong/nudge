import type { Register } from 'claude-code'

const APP = '/Applications/Nudge.app'
const INSTALL = 'brew install --cask zachdelong/tap/nudge-app'

export const register: Register = on => {
  // The hooks in hooks.json do the work; they need the menu bar app. Say so
  // once per session on a Mac without it, instead of failing silently.
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    if (e.isInteractive && (await $.fs.exists('/Applications')) && !(await $.fs.exists(APP))) {
      $.ui.toast(`Nudge needs its menu bar app: ${INSTALL}`, { timeoutMs: 15000 })
    }
    return started
  })
}
