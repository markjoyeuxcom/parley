import { describe, expect, it } from 'vitest'
import { isOpenableExternally } from './externalUrl'

/**
 * `shell.openExternal` hands a URL to the operating system, which opens it
 * with whatever is registered for its scheme. Both audits flagged that the two
 * navigation handlers passed one straight through.
 */

describe('what may be handed to the OS', () => {
  it('opens the web', () => {
    expect(isOpenableExternally('https://example.com/x?y=1')).toBe(true)
    expect(isOpenableExternally('http://localhost:5173/')).toBe(true)
    expect(isOpenableExternally('mailto:someone@example.com')).toBe(true)
  })

  it('refuses schemes that reach the filesystem or another app', () => {
    for (const url of [
      'file:///etc/passwd',
      'file:///Applications/Calculator.app',
      'smb://attacker/share',
      'ftp://example.com/x',
      // Any installed app can claim a scheme; none of them are ours to open.
      'zoommtg://zoom.us/join?confno=1',
      'ms-msdt:/id',
      'vscode://file/etc/hosts',
    ]) {
      expect(isOpenableExternally(url), url).toBe(false)
    }
  })

  it('refuses javascript: and data:, which are not somewhere to go', () => {
    expect(isOpenableExternally('javascript:alert(1)')).toBe(false)
    expect(isOpenableExternally('data:text/html,<script>alert(1)</script>')).toBe(false)
  })

  it('refuses things that are not URLs', () => {
    expect(isOpenableExternally('')).toBe(false)
    expect(isOpenableExternally('/Users/someone/secret')).toBe(false)
    expect(isOpenableExternally('example.com')).toBe(false)
  })

  it('is not fooled by a scheme that merely starts the same way', () => {
    // `new URL` normalises the protocol, so this is really a check that we
    // compare the parsed scheme rather than the string's prefix.
    expect(isOpenableExternally('https-evil://example.com')).toBe(false)
    expect(isOpenableExternally('HTTPS://example.com')).toBe(true)
  })
})
