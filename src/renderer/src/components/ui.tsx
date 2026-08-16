import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { X } from 'lucide-react'

export function Chip({
  children,
  tone = '',
  title,
}: {
  children: ReactNode
  tone?: string
  title?: string
}): ReactNode {
  return (
    <span className={`chip ${tone}`} title={title}>
      {children}
    </span>
  )
}

export function Dot({ tone = '', title }: { tone?: string; title?: string }): ReactNode {
  return <span className={`dot ${tone}`} title={title} />
}

export function Spinner(): ReactNode {
  return <span className="spinner" role="progressbar" aria-label="working" />
}

export function Label({ children }: { children: ReactNode }): ReactNode {
  return <div className="label">{children}</div>
}

export function Stat({
  value,
  label,
  note,
}: {
  value: ReactNode
  label: string
  note?: string
}): ReactNode {
  return (
    <div className="stat">
      <div className="stat__label">{label}</div>
      <div className="stat__value">{value}</div>
      {note ? <div className="stat__note">{note}</div> : null}
    </div>
  )
}

/**
 * A 0–10 score as a thin rule plus its number.
 *
 * The number is always present: a bar alone forces the reader to estimate, and
 * these values get compared across sessions.
 */
export function Meter({ value, max = 10 }: { value: number; max?: number }): ReactNode {
  const pct = Math.max(0, Math.min(100, (value / max) * 100))
  return (
    <>
      <div className="meter__track">
        <div className="meter__fill" style={{ width: `${pct}%` }} />
      </div>
      <div className="meter__value tnum">{value.toFixed(1)}</div>
    </>
  )
}

export function Field({
  label,
  hint,
  children,
}: {
  label?: string
  hint?: string
  children: ReactNode
}): ReactNode {
  return (
    <div className="field">
      {label ? <div className="field__label">{label}</div> : null}
      {children}
      {hint ? <div className="field__hint">{hint}</div> : null}
    </div>
  )
}

export function Empty({
  title,
  body,
  action,
  compact = false,
}: {
  title: string
  body?: string
  action?: ReactNode
  /**
   * One quiet line instead of a full-height block.
   *
   * For a panel that is NOT what its screen is about. A setup panel with
   * nothing in it still has to explain itself, but it should cost a line —
   * two of them at full height pushed the actual content of a view below the
   * fold and made the page look like it had nothing in it.
   */
  compact?: boolean
}): ReactNode {
  if (compact) {
    return (
      <div className="empty empty--compact">
        <span className="empty__title">{title}</span>
        {body ? <span className="empty__body">{body}</span> : null}
        {action}
      </div>
    )
  }
  return (
    <div className="empty">
      <div className="empty__title">{title}</div>
      {body ? <div className="empty__body">{body}</div> : null}
      {action}
    </div>
  )
}

export function Panel({
  title,
  actions,
  children,
  flush,
}: {
  title?: string
  actions?: ReactNode
  children: ReactNode
  flush?: boolean
}): ReactNode {
  return (
    <div className="panel">
      {title || actions ? (
        <div className="panel__header">
          <div className="panel__title">{title}</div>
          {actions ? <div className="row row--tight">{actions}</div> : null}
        </div>
      ) : null}
      <div className={flush ? 'panel__body panel__body--flush' : 'panel__body'}>{children}</div>
    </div>
  )
}

/**
 * A small anchored menu.
 *
 * `children` receives a `close` callback so items can dismiss the menu after
 * acting. Escape and any outside click also close it.
 */
export function Menu({
  label,
  title,
  children,
}: {
  label: ReactNode
  title?: string
  children: (close: () => void) => ReactNode
}): ReactNode {
  const [open, setOpen] = useState(false)
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null)
  const rootRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onDown = (event: MouseEvent): void => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false)
    }
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  // The panel is fixed-positioned and measured after it renders, because an
  // absolute panel is clipped by any overflow:hidden ancestor — a pane's
  // rounded-corner clip was eating its own action menu. Fixed escapes the
  // clip; the clamp keeps a tall or wide menu inside the window.
  useLayoutEffect(() => {
    if (!open) {
      setPos(null)
      return
    }
    const trigger = rootRef.current
    const panel = panelRef.current
    if (!trigger || !panel) return
    const rect = trigger.getBoundingClientRect()
    setPos({
      top: Math.max(8, Math.min(rect.bottom + 4, window.innerHeight - panel.offsetHeight - 8)),
      left: Math.max(8, Math.min(rect.left, window.innerWidth - panel.offsetWidth - 8)),
    })
  }, [open])

  return (
    <div className="menu" ref={rootRef}>
      <button
        className="btn btn--sm"
        title={title}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        {label}
      </button>
      {open ? (
        <div
          className="menu__panel"
          role="menu"
          ref={panelRef}
          style={
            pos
              ? { position: 'fixed', top: pos.top, left: pos.left }
              : { position: 'fixed', visibility: 'hidden' }
          }
        >
          {children(() => setOpen(false))}
        </div>
      ) : null}
    </div>
  )
}

export function MenuItem({
  children,
  selected,
  onClick,
}: {
  children: ReactNode
  selected?: boolean
  onClick: () => void
}): ReactNode {
  return (
    <button className={`menu__item ${selected ? 'is-selected' : ''}`} role="menuitem" onClick={onClick}>
      <span className="menu__tick">{selected ? '✓' : ''}</span>
      <span className="menu__label">{children}</span>
    </button>
  )
}

export function MenuSection({ children }: { children: ReactNode }): ReactNode {
  return <div className="menu__section">{children}</div>
}

/**
 * Modal dialog.
 *
 * Escape closes, clicking the scrim closes, and focus moves inside on open so a
 * keyboard user is not left behind the modal. Focus is restored on close.
 */
export function Dialog({
  title,
  subtitle,
  onClose,
  footer,
  wide,
  children,
}: {
  title: string
  subtitle?: string
  onClose: () => void
  footer?: ReactNode
  wide?: boolean
  children: ReactNode
}): ReactNode {
  const surfaceRef = useRef<HTMLDivElement>(null)
  const restoreTo = useRef<Element | null>(null)

  /**
   * Focus the first field, once, and give it back on the way out.
   *
   * Deliberately `[]` and not `[onClose]`. Callers pass an inline arrow, so
   * `onClose` is a new identity on every render of whatever owns the dialog —
   * and an autofocus keyed on it re-ran on every one of those, dragging focus
   * back to the first field. Clicking the second field gave it up instantly,
   * which made the roster's CLI, model and effort controls unusable.
   */
  useEffect(() => {
    restoreTo.current = document.activeElement
    const first = surfaceRef.current?.querySelector<HTMLElement>(
      'input, textarea, select, button:not([disabled])',
    )
    first?.focus()
    return () => {
      if (restoreTo.current instanceof HTMLElement) restoreTo.current.focus()
    }
  }, [])

  // The key handler DOES want the current onClose, and rebinding a listener
  // costs nothing — it is only focus that must not be touched again.
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        onClose()
      }
    }
    document.addEventListener('keydown', onKey, true)
    return () => document.removeEventListener('keydown', onKey, true)
  }, [onClose])

  return (
    <div
      className="overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <div
        className={wide ? 'dialog dialog--wide' : 'dialog'}
        ref={surfaceRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <div className="dialog__header">
          <div className="row">
            <div className="dialog__title spacer">{title}</div>
            <button className="btn btn--subtle btn--icon btn--sm" onClick={onClose} aria-label="Close">
              <X size={14} strokeWidth={2} />
            </button>
          </div>
          {subtitle ? <div className="dialog__subtitle">{subtitle}</div> : null}
        </div>
        <div className="dialog__body">{children}</div>
        {footer ? <div className="dialog__footer">{footer}</div> : null}
      </div>
    </div>
  )
}
