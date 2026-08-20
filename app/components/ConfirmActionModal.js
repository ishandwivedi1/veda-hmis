'use client';

// Generic confirm-before-you-commit modal for any action that's easy to
// mis-click and hard to walk back -- finalizing a record, routing a
// patient onward, closing a session, etc. Deliberately just title/
// description/labels so one component covers every caller instead of
// each screen growing its own near-identical copy.
export default function ConfirmActionModal({
  icon = 'ti-alert-circle',
  iconColor = 'var(--teal)',
  iconBg = 'rgba(13,148,136,.12)',
  title,
  description,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  workingLabel = 'Working...',
  onConfirm,
  onCancel,
  loading = false,
}) {
  return (
    <div onClick={loading ? undefined : onCancel} style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ background: '#fff', borderRadius: 12, padding: 20, maxWidth: 420, width: '100%', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
          <span style={{ width: 34, height: 34, borderRadius: '50%', background: iconBg, color: iconColor, display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <i className={`ti ${icon}`} style={{ fontSize: 18 }}></i>
          </span>
          <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--g800)' }}>{title}</div>
        </div>
        <div style={{ fontSize: 13, color: 'var(--g600)', marginBottom: 18, lineHeight: 1.5 }}>{description}</div>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button type="button" className="btn btn-sm" onClick={onCancel} disabled={loading}>{cancelLabel}</button>
          <button type="button" className="btn btn-sm btn-primary" onClick={onConfirm} disabled={loading}>{loading ? workingLabel : confirmLabel}</button>
        </div>
      </div>
    </div>
  );
}
