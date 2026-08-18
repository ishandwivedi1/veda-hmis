'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import {
  listPrintTemplates, getPrintTemplate, savePrintTemplate, resetPrintTemplate, previewTemplateHtml,
  getHospitalSettings, saveHospitalSettings,
} from '@/app/print-templates/actions';

const PLACEHOLDER_REFERENCE = {
  invoice_opd: [
    'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
    'hospital_city_state_pin', 'hospital_phone', 'hospital_email', 'terms_text', '{{{logo_html}}}',
    'patient_id', 'patient_name', 'patient_mobile', 'patient_age', 'patient_gender', 'procedure',
    'bill_no', 'bill_date', 'visit_date', 'doctor_name', 'doctor_regn_no',
    'items (loop: sno, name, qty, rate, amount)', 'gross_amount', 'discount', 'net_amount',
    'payments (loop: date, ref_number, amount)', 'total_paid',
  ],
};
PLACEHOLDER_REFERENCE.invoice_surgery = [...PLACEHOLDER_REFERENCE.invoice_opd, 'package_name', 'discharge_date'];

PLACEHOLDER_REFERENCE.receipt = [
  'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
  'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
  'patient_name', 'patient_id', 'patient_mobile',
  'receipt_no', 'receipt_date', 'payment_type_label', 'collected_by',
  'amount_received', 'amount_in_words',
  '{{#if hasAllocations}}...{{/if}}', 'allocations (loop: invoiceNumber, amount)',
  'modes (loop: mode, amount)', '{{#if reference}}...{{/if}}', '{{#if remarks}}...{{/if}}',
];
PLACEHOLDER_REFERENCE.receipt_advance = PLACEHOLDER_REFERENCE.receipt;

PLACEHOLDER_REFERENCE.opd_case_sheet = [
  'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
  'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
  'patient_id', 'patient_name', 'patient_mobile', 'patient_age', 'patient_gender',
  'visit_date', 'visit_type', 'doctor_name', 'doctor_regn_no',
  '{{#if chief_complaint}}...{{/if}}', 'hx_duration', 'hx_laterality', 'hx_hopi',
  '{{#if hasHistory}}...{{/if}}', 'historyLines (loop: label, text -- Ocular/Medical/Family/Drug History, Allergy)',
  '{{#if hasVision}}...{{/if}}', 're_vision_unaided', 'le_vision_unaided', 're_vision_glasses', 'le_vision_glasses',
  're_vision_ph', 'le_vision_ph', 're_vision_near', 'le_vision_near', 're_iop', 'le_iop', 'iop_method',
  '{{#if hasRefraction}}...{{/if}}', 're_refraction', 'le_refraction',
  '{{#if hasAdditionalTests}}...{{/if}}', 'additionalTests (loop: label, value -- K1/K2, axial length, pachymetry, etc.)',
  '{{#if hasOptObservations}}...{{/if}}', 'optObservations',
  '{{#if hasExamination}}...{{/if}}', '{{#if hasAnyExamFindings}}...{{else}}...{{/if}}',
  '{{#if hasExamFindingsWithout}}...{{/if}}', 'examFindingsWithout (loop: structure, eye, finding -- abnormal only)',
  '{{#if hasExamFindingsWith}}...{{/if}}', 'examFindingsWith (loop: structure, eye, finding -- abnormal only)',
  '{{#if hasExamExtra}}...{{/if}}', 'examExtra (loop: label, value -- CDR, gonioscopy, disc appearance per stage, remarks)',
  '{{#if hasDiagnoses}}...{{/if}}', 'diagnoses (loop: name, eye, notes)',
  '{{#if hasPrescriptions}}...{{/if}}', 'prescriptions (loop: drug, eye, dosage, frequency, duration)',
  '{{#if advice}}...{{/if}}', '{{#if followup_text}}...{{/if}}',
];

PLACEHOLDER_REFERENCE.glasses_prescription = [
  'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
  'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
  'patient_id', 'patient_name', 'patient_age', 'patient_gender', 'rx_date', 'va_scale',
  '{{#if hasDistRx}}...{{/if}}', 'dist_re_sph', 'dist_re_cyl', 'dist_re_axis', 'dist_re_va',
  'dist_le_sph', 'dist_le_cyl', 'dist_le_axis', 'dist_le_va',
  '{{#if hasNearRx}}...{{/if}}', 'near_re_sph', 'near_re_cyl', 'near_re_axis', 'near_re_va',
  'near_le_sph', 'near_le_cyl', 'near_le_axis', 'near_le_va',
  'ipd', 'optometrist_name', 'doctor_name', 'doctor_regn_no',
];

PLACEHOLDER_REFERENCE.biometry_report = [
  'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
  'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
  'patient_id', 'patient_name', 'patient_age', 'patient_gender', 'visit_number', 'report_date',
  'procedure_name', 'surgical_eye', 'verified_by_name', 'verified_by_regn_no',
  '{{#if hasReReadings}}...{{/if}}', '{{#each reSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
  '{{#if hasLeReadings}}...{{/if}}', '{{#each leSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
  '{{#if hasRecommendations}}...{{/if}}', '{{#each recommendations}}...brandModel, rePower, lePower...{{/each}}',
  '{{#if hasNotes}}...{{/if}}', 'notes',
];

PLACEHOLDER_REFERENCE.discharge_summary = [
  'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
  'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
  'patient_id', 'patient_name', 'patient_age', 'patient_gender', 'patient_mobile',
  'surgeon_name', 'admission_date', 'surgery_date', 'discharge_date', 'procedure_name', 'eye',
  'iol_lines (loop: eye, text)',
  '{{#unless hasMedications}}...{{/unless}}', 'medications (loop: name, sig)',
  '{{#if hasDischargeNotes}}...{{/if}}', 'discharge_notes', 'discharge_instructions',
  'followups (loop: visit_label, date, status)',
];

PLACEHOLDER_REFERENCE.investigation_report = [
  'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
  'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
  'patient_id', 'patient_name', 'patient_age', 'patient_gender', 'patient_mobile',
  'investigation_name', 'investigation_type', 'eye', 'doctor_name', 'ordered_date', 'completed_date',
  '{{#if isUnable}}...{{else}}...{{/if}}', 'unable_reason',
  '{{#if hasFields}}...{{/if}}', 'fields (loop: label, value)',
  '{{#if hasNotes}}...{{/if}}', 'result_notes',
  'technician_name', '{{#if hasVerifiedBy}}...{{/if}}', 'verified_by_name',
];

const SETTINGS_FIELDS = [
  { key: 'name', label: 'Hospital Name' },
  { key: 'unit_line', label: 'Unit Line (e.g. "A Unit of...")' },
  { key: 'regn_no', label: 'Hospital Registration No' },
  { key: 'address_line1', label: 'Address Line 1' },
  { key: 'address_line2', label: 'Address Line 2' },
  { key: 'city_state_pin', label: 'City, State - PIN' },
  { key: 'phone', label: 'Phone Number(s)' },
  { key: 'email', label: 'Email' },
  { key: 'terms_text', label: 'Terms & Conditions text' },
];

function HospitalSettingsPanel() {
  const [settings, setSettings] = useState(null);
  const [saving, setSaving] = useState(false);
  const [saveMsg, setSaveMsg] = useState('');
  const fileInputRef = useRef(null);

  const load = useCallback(async () => { setSettings(await getHospitalSettings()); }, []);
  useEffect(() => { load(); }, [load]);

  function update(key, value) {
    setSettings((prev) => ({ ...prev, [key]: value }));
    setSaveMsg('');
  }

  function handleLogoFile(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 1024 * 1024) { setSaveMsg('Logo image should be under 1MB.'); return; }
    const reader = new FileReader();
    reader.onload = () => update('logo_data_url', reader.result);
    reader.readAsDataURL(file);
  }

  async function handleSave() {
    setSaving(true);
    const result = await saveHospitalSettings(settings);
    setSaving(false);
    setSaveMsg(result.error || 'Saved -- applies to every template automatically.');
  }

  if (!settings) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>;

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-head" style={{ marginBottom: 10 }}>
        <div className="card-title"><i className="ti ti-building-hospital" style={{ color: 'var(--blue)' }}></i> Hospital Settings</div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {saveMsg && <span style={{ fontSize: 11.5, color: saveMsg.includes('under') ? 'var(--red)' : 'var(--green)' }}>{saveMsg}</span>}
          <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Saving...' : 'Save'}</button>
        </div>
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 14 }}>
        This information -- including the logo -- appears on every print template automatically. Edit it once here rather than in each template.
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr', gap: 14, alignItems: 'center', marginBottom: 16 }}>
        <div>
          <div style={{
            width: 100, height: 100, border: '1.5px dashed var(--g300)', borderRadius: 10,
            display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden', background: '#fff',
          }}>
            {settings.logo_data_url
              ? <img src={settings.logo_data_url} alt="Logo" style={{ maxWidth: '100%', maxHeight: '100%', objectFit: 'contain' }} />
              : <i className="ti ti-photo" style={{ fontSize: 28, color: 'var(--g300)' }}></i>}
          </div>
        </div>
        <div>
          <label className="flbl">Hospital Logo</label>
          <input ref={fileInputRef} type="file" accept="image/png,image/jpeg,image/svg+xml" onChange={handleLogoFile} className="fi fi-sm" />
          <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 4 }}>PNG, JPG, or SVG -- under 1MB. Falls back to a default mark if none is uploaded.</div>
          {settings.logo_data_url && (
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11, marginTop: 6 }} onClick={() => update('logo_data_url', null)}>Remove logo</button>
          )}
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
        {SETTINGS_FIELDS.map((f) => (
          <div key={f.key} style={f.key === 'terms_text' ? { gridColumn: 'span 2' } : undefined}>
            <label className="flbl">{f.label}</label>
            <input className="fi fi-sm" value={settings[f.key] || ''} onChange={(e) => update(f.key, e.target.value)} />
          </div>
        ))}
      </div>

      {/* LETTERHEAD / PRE-PRINTED PAPER -- when the front desk prints
          onto stationery that already has the hospital header printed
          on it (letterhead / doctor's prescription pad), the digital
          header would duplicate it. These let each print type hide its
          own header and leave blank space matching the pad's header
          height instead. */}
      <div style={{ marginTop: 20, paddingTop: 16, borderTop: '1px solid var(--g100)' }}>
        <div className="card-title" style={{ marginBottom: 4, fontSize: 13 }}>
          <i className="ti ti-file-text" style={{ color: 'var(--amber)' }}></i> Letterhead / Pre-Printed Paper
        </div>
        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 12 }}>
          For OPD Case Sheet and Glasses Prescription printouts made on stationery that already carries the hospital header (letterhead / prescription pad) -- hide the digital header and leave blank space for it instead.
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5, cursor: 'pointer' }}>
            <input
              type="checkbox"
              checked={!!settings.case_sheet_hide_header}
              onChange={(e) => update('case_sheet_hide_header', e.target.checked)}
            />
            Hide header on OPD Case Sheet
          </label>
          <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5, cursor: 'pointer' }}>
            <input
              type="checkbox"
              checked={!!settings.glasses_rx_hide_header}
              onChange={(e) => update('glasses_rx_hide_header', e.target.checked)}
            />
            Hide header on Glasses Prescription
          </label>
        </div>

        <div style={{ maxWidth: 260 }}>
          <label className="flbl">Blank space to leave at top (cm)</label>
          <input
            type="number" step="0.1" min="0" max="15"
            className="fi fi-sm"
            value={settings.print_letterhead_space_cm ?? 5}
            onChange={(e) => update('print_letterhead_space_cm', e.target.value === '' ? '' : Number(e.target.value))}
          />
          <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 4 }}>
            Matches the header height already printed on your letterhead / prescription pad. Applies whenever a header above is hidden. Default 5cm.
          </div>
        </div>
      </div>
    </div>
  );
}

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

      <HospitalSettingsPanel />

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
            Select a template on the left to edit its layout.
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
                Hospital name, address, and logo come from Hospital Settings above automatically. Edit the layout below for anything specific to this document -- {'{{tokens}}'} get replaced with real data when printed. Preview updates automatically as you type.
              </div>

              <details style={{ marginBottom: 10 }}>
                <summary style={{ fontSize: 11.5, color: 'var(--blue)', cursor: 'pointer' }}>Available placeholders</summary>
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 6, lineHeight: 1.8 }}>
                  {(PLACEHOLDER_REFERENCE[activeKey] || []).map((p) => (
                    <code key={p} style={{ background: 'var(--g100)', padding: '2px 6px', borderRadius: 4, marginRight: 6, display: 'inline-block', marginBottom: 4 }}>
                      {p.startsWith('{{') ? p : `{{${p}}}`}
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

