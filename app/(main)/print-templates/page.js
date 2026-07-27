'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { listPrintTemplates, getPrintTemplate, savePrintTemplate, resetPrintTemplate, previewTemplateHtml } from '@/app/print-templates/actions';

const PLACEHOLDER_REFERENCE = {
  invoice: [
    'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
    'hospital_city_state_pin', 'hospital_phone', 'hospital_email', 'terms_text',
    'patient_id', 'patient_name', 'patient_mobile', 'patient_age', 'patient_gender', 'procedure',
    'bill_no', 'bill_date', 'visit_date', 'doctor_name', 'doctor_regn_no',
    'items (loop: sno, name, qty, rate, amount)', 'gross_amount', 'discount', 'net_amount',
    'payments (loop: date, ref_number, amount)', 'total_paid',
  ],
};

export default function PrintTemplatesPage() {
  const [templates, setTemplates] = useState([]);
  const [loading, setLoading] = useState(true);
  const [activeKey, setActiveKey] = useState(null);
  const [html, setHtml] = useState('');
  const [previewHtml, setPreviewHtml] = useState('');
  const [previewError, setPreviewError] = useState('');
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState('');
  const debounceRef = useRef(null);

  const refresh = useCallback(async () => {
    setTemplates(await listPrintTemplates());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function openTemplate(key) {
    setActiveKey(key);
    setSaveMsg('');
    const t = await getPrintTemplate(key);
    setHtml(t.html);
  }

  // Debounced live preview -- re-renders against sample data ~500ms
  // after typing stops, rather than on every keystroke.
  useEffect(() => {
    if (!activeKey) return;
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(async () => {
      const result = await previewTemplateHtml(activeKey, html);
      if (result.error) { setPreviewError(result.error); return; }
      setPreviewError('');
      setPreviewHtml(result.html);
    }, 500);
    return () => clearTimeout(debounceRef.current);
  }, [html, activeKey]);

  async function handleSave() {
    setSaving(true);
    setSaveMsg('');
    const result = await savePrintTemplate(activeKey, html);
    setSaving(false);
    if (result.error) { setPreviewError(result.error); return; }
    setSaveMsg('Saved.');
    refresh();
  }

  async function handleReset() {
    if (!window.confirm('Reset this template to the built-in default? Any customizations will be lost.')) return;
    setSaving(true);
    await resetPrintTemplate(activeKey);
    setSaving(false);
    const t = await getPrintTemplate(activeKey);
    setHtml(t.html);
    setSaveMsg('Reset to default.');
    refresh();
  }

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>;

  const activeMeta = templates.find((t) => t.key === activeKey);

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-file-invoice" style={{ color: 'var(--blue)' }}></i> Print Templates</div>
        <div style={{ fontSize: 12.5, color: 'var(--g500)' }}>
          Bills, receipts, reports, forms, and summaries printed across the app -- each one is an editable HTML template, not fixed layout.
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 20, alignItems: 'start' }}>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>Templates</div>
          {templates.map((t) => (
            <button
              key={t.key}
              onClick={() => !t.comingSoon && openTemplate(t.key)}
              disabled={t.comingSoon}
              className="btn"
              style={{
                width: '100%', textAlign: 'left', marginBottom: 6, display: 'block',
                background: activeKey === t.key ? 'var(--blue-lt)' : t.comingSoon ? 'var(--g50)' : '',
                borderColor: activeKey === t.key ? 'var(--blue)' : '',
                cursor: t.comingSoon ? 'not-allowed' : 'pointer', opacity: t.comingSoon ? .6 : 1,
              }}
            >
              <div style={{ fontWeight: 600, fontSize: 12.5 }}>{t.name}</div>
              <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>
                {t.comingSoon ? 'Coming soon' : t.customized ? `Customized -- ${t.updatedBy || 'someone'}` : 'Using default'}
              </div>
            </button>
          ))}
        </div>

        {!activeKey && (
          <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>
            Select a template on the left to edit it.
          </div>
        )}

        {activeKey && (
          <div>
            <div className="card" style={{ marginBottom: 16 }}>
              <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
                <div className="card-title">{activeMeta?.name}</div>
                <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                  {saveMsg && <span style={{ fontSize: 11.5, color: 'var(--green)' }}>{saveMsg}</span>}
                  {activeMeta?.customized && (
                    <button className="btn btn-sm" onClick={handleReset} disabled={saving}>Reset to Default</button>
                  )}
                  <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>
                    {saving ? 'Saving...' : 'Save'}
                  </button>
                </div>
              </div>

              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                Edit the HTML below -- {'{{tokens}}'} get replaced with real data when printed. Preview updates automatically as you type.
              </div>

              <details style={{ marginBottom: 10 }}>
                <summary style={{ fontSize: 11.5, color: 'var(--blue)', cursor: 'pointer' }}>Available placeholders</summary>
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 6, lineHeight: 1.8 }}>
                  {(PLACEHOLDER_REFERENCE[activeKey] || []).map((p) => (
                    <code key={p} style={{ background: 'var(--g100)', padding: '2px 6px', borderRadius: 4, marginRight: 6, display: 'inline-block', marginBottom: 4 }}>
                      {`{{${p}}}`}
                    </code>
                  ))}
                </div>
              </details>

              <textarea
                className="fi"
                value={html}
                onChange={(e) => setHtml(e.target.value)}
                spellCheck={false}
                style={{ width: '100%', height: 400, fontFamily: 'monospace', fontSize: 12, lineHeight: 1.5, resize: 'vertical' }}
              />
            </div>

            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-eye" style={{ color: 'var(--teal)' }}></i> Preview (sample data)</div>
              {previewError && <div className="msg-err">{previewError}</div>}
              {!previewError && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
                  <iframe title="Template preview" srcDoc={previewHtml} style={{ width: '100%', height: 700, border: 'none' }} />
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
