'use client';

import { useState, useEffect, useRef } from 'react';
import { uploadAttachment, getAttachments, deleteAttachment } from '@/lib/attachments';

function formatSize(bytes) {
  if (!bytes) return '--';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export default function AttachmentUploader({ entityType, entityId, title = 'Reports & Documents' }) {
  const [files, setFiles] = useState([]);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const inputRef = useRef(null);

  async function refresh() {
    const result = await getAttachments(entityType, entityId);
    setFiles(result);
  }

  useEffect(() => { refresh(); }, [entityType, entityId]);

  async function handleFileSelect(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    setError('');
    setUploading(true);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', entityType);
    formData.append('entityId', entityId);
    const result = await uploadAttachment(formData);
    setUploading(false);
    if (inputRef.current) inputRef.current.value = '';
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleDelete(a) {
    if (!window.confirm(`Delete "${a.file_name}"? This cannot be undone.`)) return;
    await deleteAttachment(a.id, a.storage_path);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10 }}>
        <div className="card-title"><i className="ti ti-paperclip" style={{ color: 'var(--indigo)' }}></i> {title}</div>
        <label className="btn btn-sm" style={{ cursor: uploading ? 'default' : 'pointer', opacity: uploading ? 0.6 : 1, marginBottom: 0 }}>
          <i className="ti ti-upload"></i> {uploading ? 'Uploading...' : 'Upload'}
          <input ref={inputRef} type="file" accept="application/pdf,image/jpeg,image/png,image/jpg" onChange={handleFileSelect} disabled={uploading} style={{ display: 'none' }} />
        </label>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {files.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No reports uploaded yet.</div>}

      {files.map((a) => (
        <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 0', borderBottom: '1px solid var(--g100)' }}>
          <i className={`ti ${a.mime_type === 'application/pdf' ? 'ti-file-type-pdf' : 'ti-photo'}`} style={{ color: 'var(--g400)', fontSize: 16 }}></i>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 12, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.file_name}</div>
            <div style={{ fontSize: 10, color: 'var(--g400)' }}>
              {formatSize(a.file_size)} -- {a.profiles?.full_name || 'Staff'} -- {new Date(a.uploaded_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            </div>
          </div>
          {a.url && <a href={a.url} target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '3px 9px', fontSize: 11 }}>View</a>}
          <button className="btn" style={{ padding: '3px 9px', fontSize: 11 }} onClick={() => handleDelete(a)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
        </div>
      ))}
    </div>
  );
}
