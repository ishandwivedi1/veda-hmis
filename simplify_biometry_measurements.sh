#!/bin/bash
set -e

echo "==> Simplifying Biometry module: removing Lens Thickness field, both-eye completion restriction, and IOL Recommendations"

if [ ! -d "app/(main)/biometry" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/biometry not found here)."
  exit 1
fi

cat > /tmp/biometry_simplify.patch << 'PATCH_EOF'
diff --git a/app/(main)/biometry/[id]/workspace.js b/app/(main)/biometry/[id]/workspace.js
index cc0b81b..d42bf88 100644
--- a/app/(main)/biometry/[id]/workspace.js
+++ b/app/(main)/biometry/[id]/workspace.js
@@ -4,9 +4,7 @@ import { useState, useEffect } from 'react';
 import { useRouter } from 'next/navigation';
 import {
   getBiometryDetail, saveBiometryDraft, markBiometryMeasured,
-  addIolRecommendation, removeIolRecommendation,
 } from '../actions';
-import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
 import AttachmentUploader from '@/app/components/AttachmentUploader';
 
 const MEAS_FIELDS = [
@@ -14,14 +12,13 @@ const MEAS_FIELDS = [
   { key: 'k1', label: 'K1', unit: 'D' },
   { key: 'k2', label: 'K2', unit: 'D' },
   { key: 'acd', label: 'ACD', unit: 'mm' },
-  { key: 'lt', label: 'Lens Thickness', unit: 'mm' },
   { key: 'wtw', label: 'White-to-White', unit: 'mm' },
 ];
 const DEVICES = ['ZEISS IOLMaster 700', 'Haag-Streit Lenstar', 'NIDEK AL-Scan', 'Manual A-Scan'];
 const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];
 
 function emptySet(device) {
-  return { device, axl: '', k1: '', k2: '', acd: '', lt: '', wtw: '' };
+  return { device, axl: '', k1: '', k2: '', acd: '', wtw: '' };
 }
 function isComplete(set) {
   return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
@@ -72,69 +69,8 @@ function EyeSets({ label, eyeKey, sets, onFieldChange, onRemoveSet, onAddSet, di
   );
 }
 
-function RecommendationsSection({ recordId, recommendations, catalog, disabled, onSaved }) {
-  const [catalogId, setCatalogId] = useState('');
-  const [rePower, setRePower] = useState('');
-  const [lePower, setLePower] = useState('');
-  const [error, setError] = useState('');
-
-  async function handleAdd() {
-    setError('');
-    const result = await addIolRecommendation(recordId, catalogId, rePower, lePower);
-    if (result.error) { setError(result.error); return; }
-    setCatalogId(''); setRePower(''); setLePower('');
-    onSaved();
-  }
-
-  return (
-    <div className="card" style={{ marginBottom: 12 }}>
-      <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> IOL Recommendations (from device printout)</div>
-      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
-        For each IOL brand/model the device evaluated, enter the power it recommends per eye -- transcribed straight from the printout, not calculated here.
-      </div>
-      {error && <div className="msg-err" style={{ marginBottom: 8 }}>{error}</div>}
-
-      {recommendations.length > 0 && (
-        <table className="tbl" style={{ marginBottom: 10 }}>
-          <thead><tr><th>Brand / Model</th><th>RE Power</th><th>LE Power</th><th></th></tr></thead>
-          <tbody>
-            {recommendations.map((r) => (
-              <tr key={r.id}>
-                <td>{r.master_iol_catalog?.brand} {r.master_iol_catalog?.model}</td>
-                <td>{r.re_power ?? '--'}</td>
-                <td>{r.le_power ?? '--'}</td>
-                <td>
-                  {!disabled && (
-                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeIolRecommendation(r.id); onSaved(); }}>
-                      <i className="ti ti-trash"></i>
-                    </button>
-                  )}
-                </td>
-              </tr>
-            ))}
-          </tbody>
-        </table>
-      )}
-
-      {!disabled && (
-        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr auto', gap: 8 }}>
-          <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
-            <option value="">Select brand/model...</option>
-            {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}</option>)}
-          </select>
-          <input className="fi fi-sm" placeholder="RE power" value={rePower} onChange={(e) => setRePower(e.target.value)} />
-          <input className="fi fi-sm" placeholder="LE power" value={lePower} onChange={(e) => setLePower(e.target.value)} />
-          <button className="btn btn-sm btn-primary" onClick={handleAdd}><i className="ti ti-plus"></i></button>
-        </div>
-      )}
-    </div>
-  );
-}
-
 export default function BiometryWorkspace({ recordId }) {
   const [record, setRecord] = useState(null);
-  const [recommendations, setRecommendations] = useState([]);
-  const [catalog, setCatalog] = useState([]);
   const [measurements, setMeasurements] = useState({ re: [], le: [] });
   const [remarks, setRemarks] = useState('');
   const [loadError, setLoadError] = useState('');
@@ -149,7 +85,6 @@ export default function BiometryWorkspace({ recordId }) {
     const result = await getBiometryDetail(recordId);
     if (result.error) { setLoadError(result.error); return; }
     setRecord(result.record);
-    setRecommendations(result.recommendations);
     setIsDoctor(!!result.isDoctor);
     const m = result.record.measurements || {};
     setMeasurements({
@@ -159,7 +94,7 @@ export default function BiometryWorkspace({ recordId }) {
     setRemarks(result.record.verify_remarks || '');
   }
 
-  useEffect(() => { refresh(); getActiveIolCatalog().then(setCatalog); }, [recordId]);
+  useEffect(() => { refresh(); }, [recordId]);
 
   if (loadError) return <div className="msg-err">{loadError}</div>;
   if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
@@ -210,7 +145,7 @@ export default function BiometryWorkspace({ recordId }) {
         </div>
         <div style={{ flex: 1 }}>
           <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
-          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Biometry (both eyes)</div>
+          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Biometry</div>
         </div>
         <span className="badge" style={{ background: isMeasured ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.15)', color: '#fff', fontSize: 11 }}>{record.status}</span>
       </div>
@@ -251,7 +186,7 @@ export default function BiometryWorkspace({ recordId }) {
           <span className={`badge ${isMeasured ? 'b-green' : 'b-gray'}`}>{isMeasured ? 'Measured' : 'Not measured'}</span>
         </div>
         <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
-          <i className="ti ti-info-circle"></i> Biometry is always done for both eyes. Add a reading per device used -- e.g. Manual A-Scan and an optical biometer both, if both were taken.
+          <i className="ti ti-info-circle"></i> Add a reading per device used -- e.g. Manual A-Scan and an optical biometer both, if both were taken. Either eye can be entered independently.
         </div>
         <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0, border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
           <div style={{ borderRight: '1px solid var(--g200)' }}>
@@ -263,8 +198,6 @@ export default function BiometryWorkspace({ recordId }) {
         </div>
       </div>
 
-      <RecommendationsSection recordId={recordId} recommendations={recommendations} catalog={catalog} disabled={!canEdit} onSaved={refresh} />
-
       <div style={{ marginBottom: 12 }}>
         <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Report (required -- IOLMaster/Lenstar printout, scanned reports)" />
       </div>
diff --git a/app/(main)/biometry/actions.js b/app/(main)/biometry/actions.js
index bcffc13..00578ba 100644
--- a/app/(main)/biometry/actions.js
+++ b/app/(main)/biometry/actions.js
@@ -3,8 +3,6 @@
 import { createClient } from '@/lib/supabase-server';
 import { logJourneyEvent } from '@/lib/journey-events';
 
-const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];
-
 // ── QUEUE ──────────────────────────────────────────────────────────
 // Biometry is patient-level now, not visit/case-level -- a session is
 // reused across every future surgical case for that patient. The queue
@@ -109,12 +107,6 @@ export async function getBiometryDetail(id) {
 
   if (error) return { error: error.message };
 
-  const { data: recommendations } = await supabase
-    .from('biometry_iol_recommendations')
-    .select('*, master_iol_catalog(brand, model, category)')
-    .eq('biometry_record_id', id)
-    .order('created_at', { ascending: true });
-
   // Once a record is Measured, opening it (e.g. via "View Report" from
   // Surgical Journey) should default to a locked, read-only view --
   // only a Doctor can unlock it to make a correction. Before Measured,
@@ -126,7 +118,7 @@ export async function getBiometryDetail(id) {
     isDoctor = me?.designation === 'Doctor';
   }
 
-  return { record: data, recommendations: recommendations || [], isDoctor };
+  return { record: data, isDoctor };
 }
 
 // Persists measurement readings without changing status -- technician
@@ -146,32 +138,13 @@ export async function saveBiometryDraft(id, measurements) {
   return { success: true };
 }
 
-function isComplete(set) {
-  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
-}
-
-// Marks the session done -- requires at least one complete reading for
-// EACH eye (biometry is always done for both eyes now) and at least
-// one IOL recommendation row entered, plus the device report attached
-// (checked by the caller via AttachmentUploader's own listing, not
-// re-verified here -- consistent with how other modules treat
-// attachments as informational rather than a hard DB gate).
+// Marks the session done -- no completeness restriction on either eye;
+// the technician can mark as measured with whatever data has been
+// entered (partial readings, single eye only, etc).
 export async function markBiometryMeasured(id, measurements, remarks) {
   const supabase = await createClient();
   const { data: userData } = await supabase.auth.getUser();
 
-  const reHasComplete = (measurements.re || []).some(isComplete);
-  const leHasComplete = (measurements.le || []).some(isComplete);
-  if (!reHasComplete || !leHasComplete) {
-    return { error: 'At least one complete reading (AXL, K1, K2, ACD) is required for BOTH eyes.' };
-  }
-
-  const { count } = await supabase
-    .from('biometry_iol_recommendations')
-    .select('id', { count: 'exact', head: true })
-    .eq('biometry_record_id', id);
-  if (!count) return { error: 'Add at least one IOL recommendation from the device printout before marking as measured.' };
-
   const devicesUsed = [...new Set([...(measurements.re || []), ...(measurements.le || [])].map((s) => s.device).filter(Boolean))];
 
   const { data, error } = await supabase
@@ -220,13 +193,9 @@ export async function markBiometryMeasured(id, measurements, remarks) {
   return { success: true };
 }
 
-// ── IOL RECOMMENDATIONS ──────────────────────────────────────────
-// The device's own printed table -- for each brand/model it evaluated,
-// what power it recommends per eye. This app records what the printout
-// says; it does not calculate anything itself.
 // Shared lock check: once a biometry record is Measured, only a
-// Doctor can modify it (readings or recommendations) -- everyone else
-// gets a read-only view. Returns null if the edit is allowed, or an
+// Doctor can modify it -- everyone else gets a read-only view.
+// Returns null if the edit is allowed, or an
 // {error} object to return straight from the calling action.
 async function assertBiometryEditable(supabase, biometryRecordId) {
   const { data: existing } = await supabase.from('biometry_records').select('status').eq('id', biometryRecordId).maybeSingle();
@@ -241,32 +210,6 @@ async function assertBiometryEditable(supabase, biometryRecordId) {
   return null;
 }
 
-export async function addIolRecommendation(biometryRecordId, iolCatalogId, rePower, lePower) {
-  const supabase = await createClient();
-  const lockError = await assertBiometryEditable(supabase, biometryRecordId);
-  if (lockError) return lockError;
-  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
-  if (!rePower && !lePower) return { error: 'Enter at least one power (RE or LE).' };
-  const { error } = await supabase.from('biometry_iol_recommendations').insert({
-    biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
-    re_power: rePower || null, le_power: lePower || null,
-  });
-  if (error) return { error: error.message };
-  return { success: true };
-}
-
-export async function removeIolRecommendation(id) {
-  const supabase = await createClient();
-  const { data: rec } = await supabase.from('biometry_iol_recommendations').select('biometry_record_id').eq('id', id).maybeSingle();
-  if (rec?.biometry_record_id) {
-    const lockError = await assertBiometryEditable(supabase, rec.biometry_record_id);
-    if (lockError) return lockError;
-  }
-  const { error } = await supabase.from('biometry_iol_recommendations').delete().eq('id', id);
-  if (error) return { error: error.message };
-  return { success: true };
-}
-
 // ── HISTORY -- cross-patient, Measured or Cancelled. ──
 export async function getBiometryHistory(patientFilter) {
   const supabase = await createClient();
diff --git a/app/(main)/print-templates/page.js b/app/(main)/print-templates/page.js
index 377c496..ca2b988 100644
--- a/app/(main)/print-templates/page.js
+++ b/app/(main)/print-templates/page.js
@@ -66,8 +66,8 @@ PLACEHOLDER_REFERENCE.biometry_report = [
   'hospital_city_state_pin', 'hospital_phone', 'hospital_email', '{{{logo_html}}}',
   'patient_id', 'patient_name', 'patient_age', 'patient_gender', 'visit_number', 'report_date',
   'procedure_name', 'surgical_eye', 'surgeon_name', 'surgeon_regn_no',
-  '{{#if hasReReadings}}...{{/if}}', '{{#each reSets}}...device, axl, k1, k2, acd, lt, wtw...{{/each}}',
-  '{{#if hasLeReadings}}...{{/if}}', '{{#each leSets}}...device, axl, k1, k2, acd, lt, wtw...{{/each}}',
+  '{{#if hasReReadings}}...{{/if}}', '{{#each reSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
+  '{{#if hasLeReadings}}...{{/if}}', '{{#each leSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
   '{{#if hasFormulaResults}}...{{/if}}', '{{#each formulaResults}}...name, power, refraction, isSelected...{{/each}}',
   'final_iol_power', 'final_iol_formula', 'final_iol_category', 'final_iol_lens', 'target_refraction', 'surgeon_notes', 'approved_date',
 ];
diff --git a/app/print-templates/actions.js b/app/print-templates/actions.js
index e4fb19f..a3905d4 100644
--- a/app/print-templates/actions.js
+++ b/app/print-templates/actions.js
@@ -236,7 +236,6 @@ const DEFAULT_TEMPLATES = {
               <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
-              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
             </table>
           </div>
@@ -257,7 +256,6 @@ const DEFAULT_TEMPLATES = {
               <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
-              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
               <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
             </table>
           </div>
PATCH_EOF

git apply --check /tmp/biometry_simplify.patch
git apply /tmp/biometry_simplify.patch
rm /tmp/biometry_simplify.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Removed 'Lens Thickness' field from biometry measurements (both eyes, and biometry print template)"
echo "  - Removed the requirement that BOTH eyes have a complete reading before marking a biometry record as Measured"
echo "  - Removed IOL Recommendations entirely from the Biometry workspace (device-printout brand/power entry UI + backing actions)"
echo ""
echo "Note: biometry_iol_recommendations table and IOL Approval module are untouched -- IOL Approval already handles"
echo "the case of zero recommendations gracefully (shows 'No recommendations recorded on the biometry report.')."
echo ""
echo "Now run:"
echo "  git add -A"
echo "  git commit -m \"Biometry: remove lens thickness field, both-eye completion restriction, and IOL recommendations\""
echo "  git push origin main"
