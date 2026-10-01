import { test, expect } from 'claude-code/testing'
import type { On } from 'claude-code'

// $.fs.exists answered from a list of paths that exist; every toast recorded.
function machine(on: On, paths: string[]) {
  const toasts: string[] = []
  on('fs.exists', ($, e) => ({ value: paths.includes(e.path) }))
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
  })
  return toasts
}

const start = { cwd: '/tmp', surface: 'terminal', isInteractive: true } as const

test('a Mac without Nudge.app gets the install line', async ($, on) => {
  const toasts = machine(on, ['/Applications'])
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start(start)
  expect(toasts.length).toBe(1)
  expect(toasts[0]).toContain('brew install --cask zachdelong/tap/nudge-app')
})

test('a Mac with Nudge.app hears nothing', async ($, on) => {
  const toasts = machine(on, ['/Applications', '/Applications/Nudge.app'])
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start(start)
  expect(toasts).toEqual([])
})

test('not a Mac: nothing', async ($, on) => {
  const toasts = machine(on, [])
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start(start)
  expect(toasts).toEqual([])
})

test('-p runs: nothing', async ($, on) => {
  const toasts = machine(on, ['/Applications'])
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  await $.session.start({ ...start, surface: null, isInteractive: false })
  expect(toasts).toEqual([])
})
