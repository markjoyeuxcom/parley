// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { useState, type ReactNode } from 'react'
import { Dialog } from './ui'

/**
 * Dialog focus.
 *
 * A dialog takes focus once, on the way in, and gives it back on the way out.
 * Doing it again is not a smaller version of the same thing — it is a dialog
 * that fights the person using it, and it shipped: the roster's CLI, model and
 * effort controls could not be clicked, because every re-render of the surface
 * that owned the dialog dragged focus back to the first field.
 */

afterEach(cleanup)

/** A dialog whose owner re-renders, passing a fresh inline onClose each time. */
function Host(): ReactNode {
  const [, setTick] = useState(0)
  return (
    <>
      <button onClick={() => setTick((t) => t + 1)}>Re-render the owner</button>
      <Dialog title="Roster" onClose={() => {}}>
        <input aria-label="Name" />
        <select aria-label="CLI">
          <option>Claude Code</option>
        </select>
      </Dialog>
    </>
  )
}

describe('Dialog', () => {
  it('takes focus once, and does not take it back', () => {
    render(<Host />)
    const cli = screen.getByLabelText('CLI')

    // Move to a later control, the way a person clicking one would. Which
    // element the dialog focuses on the way in is not the point here; that it
    // stops afterwards is.
    cli.focus()
    expect(document.activeElement).toBe(cli)

    // The owner re-renders — a new inline onClose identity every time.
    fireEvent.click(screen.getByRole('button', { name: 'Re-render the owner' }))
    fireEvent.click(screen.getByRole('button', { name: 'Re-render the owner' }))

    // Focus stays where the person put it.
    expect(document.activeElement).toBe(cli)
  })

  it('still closes on Escape after the owner re-renders', () => {
    // The key handler DOES want the current onClose, so it rebinds — the
    // split must not cost the dialog its escape hatch.
    let closed = 0
    function EscapeHost(): ReactNode {
      const [, setTick] = useState(0)
      return (
        <>
          <button onClick={() => setTick((t) => t + 1)}>Re-render</button>
          <Dialog title="Roster" onClose={() => (closed += 1)}>
            <input aria-label="Name" />
          </Dialog>
        </>
      )
    }
    render(<EscapeHost />)
    fireEvent.click(screen.getByRole('button', { name: 'Re-render' }))
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(closed).toBe(1)
  })
})
