import type { ReactNode } from 'react'
import { X } from 'lucide-react'
import { useStore } from '../state'

export function Notices(): ReactNode {
  const { state, dispatch } = useStore()
  if (!state.notices.length) return null

  return (
    <div className="notices" role="status" aria-live="polite">
      {state.notices.map((notice) => (
        <div key={notice.id} className={`notice notice--${notice.level}`}>
          <div className="notice__mark" />
          <div className="spacer selectable">{notice.message}</div>
          <button
            className="btn btn--subtle btn--icon btn--sm"
            onClick={() => dispatch({ type: 'dismissNotice', id: notice.id })}
            aria-label="Dismiss"
          >
            <X size={12} strokeWidth={2} />
          </button>
        </div>
      ))}
    </div>
  )
}
