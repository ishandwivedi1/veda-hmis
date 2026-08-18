#!/bin/bash
set -e

echo "==> Restoring IOL Recommendations (optional) and fixing the Biometry print report"

if [ ! -d "app/(main)/biometry" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/biometry not found here)."
  exit 1
fi

cat > /tmp/iol_recommendations_and_print_report.patch << 'PATCH_EOF'
diff --git a/app/(main)/biometry/[id]/workspace.js b/app/(main)/biometry/[id]/workspace.js
index dd0e7d0..9f7b000 100644
--- a/app/(main)/biometry/[id]/workspace.js
+++ b/app/(main)/biometry/[id]/workspace.js
@@ -4,7 +4,9 @@ import { useState, useEffect } from 'react';
 import { useRouter } from 'next/navigation';
 import {
   getBiometryDetail, saveBiometryDraft, markBiometryMeasured,
+  addIolRecommendation, removeIolRecommendation,
 } from '../actions';
+import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
 import AttachmentUploader from '@/app/components/AttachmentUploader';
 import { openPrintPopup } from '@/lib/printPopup';
 
@@ -70,8 +72,69 @@ function EyeSets({ label, eyeKey, sets, onFieldChange, onRemoveSet, onAddSet, di
   );
 }
 
+function RecommendationsSection({ recordId, recommendations, catalog, disabled, onSaved }) {
+  const [catalogId, setCatalogId] = useState('');
+  const [rePower, setRePower] = useState('');
+  const [lePower, setLePower] = useState('');
+  const [error, setError] = useState('');
+
+  async function handleAdd() {
+    setError('');
+    const result = await addIolRecommendation(recordId, catalogId, rePower, lePower);
+    if (result.error) { setError(result.error); return; }
+    setCatalogId(''); setRePower(''); setLePower('');
+    onSaved();
+  }
+
+  return (
+    <div className="card" style={{ marginBottom: 12 }}>
+      <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> IOL Recommendations (from device printout)</div>
+      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
+        Optional -- not required to save or mark as measured. For each IOL brand/model the device evaluated, enter the power it recommends per eye -- transcribed straight from the printout, not calculated here.
+      </div>
+      {error && <div className="msg-err" style={{ marginBottom: 8 }}>{error}</div>}
+
+      {recommendations.length > 0 && (
+        <table className="tbl" style={{ marginBottom: 10 }}>
+          <thead><tr><th>Brand / Model</th><th>RE Power</th><th>LE Power</th><th></th></tr></thead>
+          <tbody>
+            {recommendations.map((r) => (
+              <tr key={r.id}>
+                <td>{r.master_iol_catalog?.brand} {r.master_iol_catalog?.model}</td>
+                <td>{r.re_power ?? '--'}</td>
+                <td>{r.le_power ?? '--'}</td>
+                <td>
+                  {!disabled && (
+                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeIolRecommendation(r.id); onSaved(); }}>
+                      <i className="ti ti-trash"></i>
+                    </button>
+                  )}
+                </td>
+              </tr>
+            ))}
+          </tbody>
+        </table>
+      )}
+
+      {!disabled && (
+        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr auto', gap: 8 }}>
+          <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
+            <option value="">Select brand/model...</option>
+            {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}</option>)}
+          </select>
+          <input className="fi fi-sm" placeholder="RE power" value={rePower} onChange={(e) => setRePower(e.target.value)} />
+          <input className="fi fi-sm" placeholder="LE power" value={lePower} onChange={(e) => setLePower(e.target.value)} />
+          <button className="btn btn-sm btn-primary" onClick={handleAdd}><i className="ti ti-plus"></i></button>
+        </div>
+      )}
+    </div>
+  );
+}
+
 export default function BiometryWorkspace({ recordId }) {
   const [record, setRecord] = useState(null);
+  const [recommendations, setRecommendations] = useState([]);
+  const [catalog, setCatalog] = useState([]);
   const [measurements, setMeasurements] = useState({ re: [], le: [] });
   const [remarks, setRemarks] = useState('');
   const [loadError, setLoadError] = useState('');
@@ -86,6 +149,7 @@ export default function BiometryWorkspace({ recordId }) {
     const result = await getBiometryDetail(recordId);
     if (result.error) { setLoadError(result.error); return; }
     setRecord(result.record);
+    setRecommendations(result.recommendations);
     setIsDoctor(!!result.isDoctor);
     const m = result.record.measurements || {};
     setMeasurements({
@@ -95,7 +159,7 @@ export default function BiometryWorkspace({ recordId }) {
     setRemarks(result.record.verify_remarks || '');
   }
 
-  useEffect(() => { refresh(); }, [recordId]);
+  useEffect(() => { refresh(); getActiveIolCatalog().then(setCatalog); }, [recordId]);
 
   if (loadError) return <div className="msg-err">{loadError}</div>;
   if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
@@ -199,6 +263,8 @@ export default function BiometryWorkspace({ recordId }) {
         </div>
       </div>
 
+      <RecommendationsSection recordId={recordId} recommendations={recommendations} catalog={catalog} disabled={!canEdit} onSaved={refresh} />
+
       <div style={{ marginBottom: 12 }}>
         <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Report (required -- IOLMaster/Lenstar printout, scanned reports)" />
       </div>
diff --git a/app/(main)/biometry/actions.js b/app/(main)/biometry/actions.js
index 00578ba..8c58052 100644
--- a/app/(main)/biometry/actions.js
+++ b/app/(main)/biometry/actions.js
@@ -107,6 +107,12 @@ export async function getBiometryDetail(id) {
 
   if (error) return { error: error.message };
 
+  const { data: recommendations } = await supabase
+    .from('biometry_iol_recommendations')
+    .select('*, master_iol_catalog(brand, model, category)')
+    .eq('biometry_record_id', id)
+    .order('created_at', { ascending: true });
+
   // Once a record is Measured, opening it (e.g. via "View Report" from
   // Surgical Journey) should default to a locked, read-only view --
   // only a Doctor can unlock it to make a correction. Before Measured,
@@ -118,7 +124,7 @@ export async function getBiometryDetail(id) {
     isDoctor = me?.designation === 'Doctor';
   }
 
-  return { record: data, isDoctor };
+  return { record: data, recommendations: recommendations || [], isDoctor };
 }
 
 // Persists measurement readings without changing status -- technician
@@ -210,6 +216,36 @@ async function assertBiometryEditable(supabase, biometryRecordId) {
   return null;
 }
 
+// ── IOL RECOMMENDATIONS ──────────────────────────────────────────
+// The device's own printed table -- for each brand/model it evaluated,
+// what power it recommends per eye. Optional: not required to save a
+// draft or to mark the record Measured.
+export async function addIolRecommendation(biometryRecordId, iolCatalogId, rePower, lePower) {
+  const supabase = await createClient();
+  const lockError = await assertBiometryEditable(supabase, biometryRecordId);
+  if (lockError) return lockError;
+  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
+  if (!rePower && !lePower) return { error: 'Enter at least one power (RE or LE).' };
+  const { error } = await supabase.from('biometry_iol_recommendations').insert({
+    biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
+    re_power: rePower || null, le_power: lePower || null,
+  });
+  if (error) return { error: error.message };
+  return { success: true };
+}
+
+export async function removeIolRecommendation(id) {
+  const supabase = await createClient();
+  const { data: rec } = await supabase.from('biometry_iol_recommendations').select('biometry_record_id').eq('id', id).maybeSingle();
+  if (rec?.biometry_record_id) {
+    const lockError = await assertBiometryEditable(supabase, rec.biometry_record_id);
+    if (lockError) return lockError;
+  }
+  const { error } = await supabase.from('biometry_iol_recommendations').delete().eq('id', id);
+  if (error) return { error: error.message };
+  return { success: true };
+}
+
 // ── HISTORY -- cross-patient, Measured or Cancelled. ──
 export async function getBiometryHistory(patientFilter) {
   const supabase = await createClient();
diff --git a/app/(main)/print-templates/page.js b/app/(main)/print-templates/page.js
index ca2b988..33c5b61 100644
--- a/app/(main)/print-templates/page.js
+++ b/app/(main)/print-templates/page.js
@@ -65,11 +65,9 @@ PLACEHOLDER_REFERENCE.biometry_report = [
   'hospital_name', 'hospital_unit_line', 'hospital_regn_no', 'hospital_address_line1', 'hospital_address_line2',
   'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
   'patient_id', 'patient_name', 'patient_age', 'patient_gender', 'visit_number', 'report_date',
-  'procedure_name', 'surgical_eye', 'surgeon_name', 'surgeon_regn_no',
+  'procedure_name', 'surgical_eye', 'verified_by_name', 'verified_by_regn_no',
   '{{#if hasReReadings}}...{{/if}}', '{{#each reSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
   '{{#if hasLeReadings}}...{{/if}}', '{{#each leSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
-  '{{#if hasFormulaResults}}...{{/if}}', '{{#each formulaResults}}...name, power, refraction, isSelected...{{/each}}',
-  'final_iol_power', 'final_iol_formula', 'final_iol_category', 'final_iol_lens', 'target_refraction', 'surgeon_notes', 'approved_date',
 ];
 
 PLACEHOLDER_REFERENCE.discharge_summary = [
diff --git a/app/print-templates/actions.js b/app/print-templates/actions.js
index a3905d4..3b7fcbf 100644
--- a/app/print-templates/actions.js
+++ b/app/print-templates/actions.js
@@ -196,7 +196,7 @@ const DEFAULT_TEMPLATES = {
   </table>
 
   <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
-    IOL BIOMETRY &amp; POWER CALCULATION REPORT
+    IOL BIOMETRY REPORT
   </div>
 
   <!-- PATIENT / SURGICAL INFO -->
@@ -215,7 +215,6 @@ const DEFAULT_TEMPLATES = {
           <tr><td style="width: 90px; color: #444; padding: 2px 0;">DATE</td><td style="padding: 2px 0;">: <strong>{{report_date}}</strong></td></tr>
           <tr><td style="color: #444; padding: 2px 0;">PROCEDURE</td><td style="padding: 2px 0;">: <strong>{{procedure_name}}</strong></td></tr>
           <tr><td style="color: #444; padding: 2px 0;">EYE</td><td style="padding: 2px 0;">: <strong>{{surgical_eye}}</strong></td></tr>
-          <tr><td style="color: #444; padding: 2px 0;">SURGEON</td><td style="padding: 2px 0;">: <strong>{{surgeon_name}}</strong></td></tr>
         </table>
       </td>
     </tr>
@@ -231,6 +230,7 @@ const DEFAULT_TEMPLATES = {
           {{#if hasReReadings}}
           {{#each reSets}}
           <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
+            <div style="font-size: 11px; font-weight: 700; color: #1e4e8c; margin-bottom: 4px;"><i>Device:</i> {{device}}</div>
             <table style="width: 100%; font-size: 11.5px;">
               <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
@@ -251,6 +251,7 @@ const DEFAULT_TEMPLATES = {
           {{#if hasLeReadings}}
           {{#each leSets}}
           <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
+            <div style="font-size: 11px; font-weight: 700; color: #1e4e8c; margin-bottom: 4px;"><i>Device:</i> {{device}}</div>
             <table style="width: 100%; font-size: 11.5px;">
               <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
@@ -268,51 +269,12 @@ const DEFAULT_TEMPLATES = {
     </tr>
   </table>
 
-  <!-- IOL POWER CALCULATION -->
-  {{#if hasFormulaResults}}
-  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">IOL Power Calculation</div>
-  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px; font-size: 12px;">
-    <tr style="background: #e9edf2;">
-      <th style="border: 1px solid #999; padding: 7px; text-align: left;">Formula</th>
-      <th style="border: 1px solid #999; padding: 7px; text-align: center;">IOL Power</th>
-      <th style="border: 1px solid #999; padding: 7px; text-align: center;">Predicted Refraction</th>
-    </tr>
-    {{#each formulaResults}}
-    <tr style="{{#if isSelected}}background: #f0fdf4; font-weight: 700;{{/if}}">
-      <td style="border: 1px solid #999; padding: 7px;">{{name}}{{#if isSelected}} <span style="color: #16a34a;">(Selected)</span>{{/if}}</td>
-      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{power}} D</td>
-      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{refraction}}</td>
-    </tr>
-    {{/each}}
-  </table>
-  {{/if}}
-
-  <!-- FINAL APPROVED PLAN -->
-  <div style="font-size: 13px; font-weight: 700; color: #16a34a; margin-bottom: 8px; text-transform: uppercase;">Final Approved Plan</div>
-  <table style="width: 100%; border: 1.5px solid #16a34a; border-collapse: collapse; margin-bottom: 18px; background: #f0fdf4;">
-    <tr>
-      <td style="padding: 10px 14px; font-size: 12px;">
-        <table style="width: 100%; font-size: 12px;">
-          <tr><td style="width: 160px; color: #444; padding: 3px 0;">Final IOL Power</td><td style="padding: 3px 0;"><strong>{{final_iol_power}} D</strong></td></tr>
-          <tr><td style="color: #444; padding: 3px 0;">Formula Used</td><td style="padding: 3px 0;"><strong>{{final_iol_formula}}</strong></td></tr>
-          <tr><td style="color: #444; padding: 3px 0;">IOL Category</td><td style="padding: 3px 0;"><strong>{{final_iol_category}}</strong></td></tr>
-          <tr><td style="color: #444; padding: 3px 0;">Lens</td><td style="padding: 3px 0;"><strong>{{final_iol_lens}}</strong></td></tr>
-          <tr><td style="color: #444; padding: 3px 0;">Target Refraction</td><td style="padding: 3px 0;"><strong>{{target_refraction}}</strong></td></tr>
-          {{#if surgeon_notes}}
-          <tr><td style="color: #444; padding: 3px 0; vertical-align: top;">Surgeon Notes</td><td style="padding: 3px 0;">{{surgeon_notes}}</td></tr>
-          {{/if}}
-          <tr><td style="color: #444; padding: 3px 0;">Approved On</td><td style="padding: 3px 0;">{{approved_date}}</td></tr>
-        </table>
-      </td>
-    </tr>
-  </table>
-
   <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
     <tr>
       <td style="width: 100%; text-align: right; font-size: 12px; vertical-align: bottom;">
         <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px; margin-left: auto;">
-          <div style="font-weight: 600;">{{surgeon_name}}</div>
-          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{surgeon_regn_no}}</div>
+          <div style="font-weight: 600;">{{verified_by_name}}</div>
+          <div style="font-size: 10px; color: #9ca3af;">Recorded / Verified By{{#if verified_by_regn_no}} -- Reg No: {{verified_by_regn_no}}{{/if}}</div>
         </div>
       </td>
     </tr>
@@ -731,22 +693,14 @@ const SAMPLE_BIOMETRY_RAW = {
   patient: { uhid: 'VEH000031', first_name: 'Dharam', last_name: '', age: 68, gender: 'Male' },
   visit: { visit_number: 'VN26-000112' },
   record: {
-    procedure_name: 'Phacoemulsification with IOL', surgical_eye: 'RE', status: 'Approved',
-    created_at: '2026-06-01T00:00:00Z', approved_at: '2026-06-02T00:00:00Z',
+    procedure_name: 'Phacoemulsification with IOL', surgical_eye: 'RE', status: 'Measured',
+    created_at: '2026-06-01T00:00:00Z', verified_at: '2026-06-01T00:00:00Z',
     measurements: {
-      re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', lt: '4.50', wtw: '11.80' }],
-      le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', lt: '4.48', wtw: '11.75' }],
+      re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', wtw: '11.80' }],
+      le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', wtw: '11.75' }],
     },
-    formula_results: [
-      { name: 'Barrett Universal II', power: '21.5', refraction: '-0.15' },
-      { name: 'SRK/T', power: '21.0', refraction: '-0.30' },
-    ],
-    selected_formula: 'Barrett Universal II',
-    final_iol_power: '21.5', final_iol_category: 'Monofocal', target_refraction: '-0.15 D',
-    surgeon_notes: 'Aim for slight myopia. Standard monofocal, no toric correction needed.',
   },
-  surgeon: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
-  catalogItem: { brand: 'Alcon', model: 'AcrySof IQ' },
+  verifiedBy: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
 };
 
 // ── Renders the actual invoice HTML for a given invoiceId. Picks the
@@ -1387,19 +1341,14 @@ export async function renderGlassesPrescriptionHtml(assessmentId) {
 function buildBiometryReadingSets(sets) {
   return (Array.isArray(sets) ? sets : []).map((s) => ({
     device: s.device || 'Unspecified device',
-    axl: s.axl || '--', k1: s.k1 || '--', k2: s.k2 || '--', acd: s.acd || '--', lt: s.lt || '--', wtw: s.wtw || '--',
+    axl: s.axl || '--', k1: s.k1 || '--', k2: s.k2 || '--', acd: s.acd || '--', wtw: s.wtw || '--',
   }));
 }
 
-function buildBiometryReportContext(settings, { patient, visit, record, surgeon, catalogItem }) {
+function buildBiometryReportContext(settings, { patient, visit, record, verifiedBy }) {
   const reSets = buildBiometryReadingSets(record.measurements?.re);
   const leSets = buildBiometryReadingSets(record.measurements?.le);
 
-  const formulaResults = (record.formula_results || []).map((r) => ({
-    name: r.name, power: r.power || '--', refraction: r.refraction || '--',
-    isSelected: r.name === record.selected_formula,
-  }));
-
   const EYE_LABEL = { RE: 'Right Eye (RE / OD)', LE: 'Left Eye (LE / OS)', Both: 'Both Eyes (OU)', OD: 'Right Eye (RE / OD)', OS: 'Left Eye (LE / OS)', OU: 'Both Eyes (OU)' };
 
   return {
@@ -1418,29 +1367,17 @@ function buildBiometryReportContext(settings, { patient, visit, record, surgeon,
     patient_age: patient.age ?? '--',
     patient_gender: patient.gender || '--',
     visit_number: visit?.visit_number || '--',
-    report_date: fmtDate(record.approved_at || record.created_at),
+    report_date: fmtDate(record.verified_at || record.created_at),
 
     procedure_name: record.procedure_name || '--',
     surgical_eye: EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--',
-    surgeon_name: surgeon?.full_name || '--',
-    surgeon_regn_no: surgeon?.registration_no || '--',
+    verified_by_name: verifiedBy?.full_name || '--',
+    verified_by_regn_no: verifiedBy?.registration_no || null,
 
     hasReReadings: reSets.length > 0,
     reSets,
     hasLeReadings: leSets.length > 0,
     leSets,
-
-    hasFormulaResults: formulaResults.length > 0,
-    formulaResults,
-
-    isApproved: record.status === 'Approved',
-    final_iol_power: record.final_iol_power || '--',
-    final_iol_formula: record.selected_formula || '--',
-    final_iol_category: record.final_iol_category || '--',
-    final_iol_lens: catalogItem ? `${catalogItem.brand || ''} -- ${catalogItem.model || ''}`.trim() : '--',
-    target_refraction: record.target_refraction || '--',
-    surgeon_notes: record.surgeon_notes || null,
-    approved_date: record.approved_at ? fmtDate(record.approved_at) : '--',
   };
 }
 
@@ -1454,10 +1391,10 @@ export async function renderBiometryReportHtml(recordId) {
     .single();
   if (error || !record) return { error: 'Biometry record not found.' };
 
-  let surgeon = null;
+  let verifiedBy = null;
   if (record.verified_by) {
     const { data: doc } = await supabase.from('profiles').select('full_name, registration_no').eq('id', record.verified_by).maybeSingle();
-    surgeon = doc;
+    verifiedBy = doc;
   }
 
   const settings = await getHospitalSettings();
@@ -1465,8 +1402,7 @@ export async function renderBiometryReportHtml(recordId) {
     patient: record.visits?.patients || {},
     visit: record.visits,
     record,
-    surgeon,
-    catalogItem: null,
+    verifiedBy,
   });
 
   const template = await getPrintTemplate('biometry_report');
PATCH_EOF

git apply --check /tmp/iol_recommendations_and_print_report.patch
git apply /tmp/iol_recommendations_and_print_report.patch
rm /tmp/iol_recommendations_and_print_report.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Biometry workspace: IOL Recommendations (from device printout) section is back -- brand/model + RE/LE power entry, fully optional, NOT required to Save Draft or Mark as Measured"
echo "  - Biometry print report: title changed to just 'IOL BIOMETRY REPORT'"
echo "  - Biometry print report: removed 'IOL Power Calculation' and 'Final Approved Plan' sections entirely"
echo "  - Biometry print report: each reading now shows the device/machine used (e.g. 'ZEISS IOLMaster 700') directly above its measurement values"
echo "  - Biometry print report: footer signature relabeled 'Recorded / Verified By' (was mislabeled as Surgeon) since this is now purely a measurement report"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Biometry: restore optional IOL Recommendations section; simplify print report to IOL Biometry Report (readings + device only, no calc/approval sections)"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
