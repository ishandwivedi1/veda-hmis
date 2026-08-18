#!/bin/bash
set -e

echo "==> Wiring IOL Recommendations + Notes into the Biometry print report"

if [ ! -d "app/(main)/biometry" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/biometry not found here)."
  exit 1
fi

cat > /tmp/notes_and_print_fixes.patch << 'PATCH_EOF'
diff --git a/app/(main)/biometry/[id]/workspace.js b/app/(main)/biometry/[id]/workspace.js
index 9f7b000..5fd0af4 100644
--- a/app/(main)/biometry/[id]/workspace.js
+++ b/app/(main)/biometry/[id]/workspace.js
@@ -187,7 +187,7 @@ export default function BiometryWorkspace({ recordId }) {
 
   async function handleSaveDraft() {
     setError(''); setOkMsg(''); setSaving(true);
-    const result = await saveBiometryDraft(recordId, measurements);
+    const result = await saveBiometryDraft(recordId, measurements, remarks);
     setSaving(false);
     if (result.error) { setError(result.error); return; }
     setOkMsg('Draft saved.');
@@ -265,6 +265,20 @@ export default function BiometryWorkspace({ recordId }) {
 
       <RecommendationsSection recordId={recordId} recommendations={recommendations} catalog={catalog} disabled={!canEdit} onSaved={refresh} />
 
+      <div className="card" style={{ marginBottom: 12 }}>
+        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-notes" style={{ color: 'var(--amber)' }}></i> Notes</div>
+        <textarea
+          className="fi fi-sm"
+          rows={3}
+          style={{ width: '100%', resize: 'vertical' }}
+          placeholder="e.g. Optical biometry unreliable due to dense cataract, A-Scan used as backup..."
+          value={remarks}
+          onChange={(e) => setRemarks(e.target.value)}
+          disabled={!canEdit}
+        />
+        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 4 }}>Prints on the Biometry Report if filled in.</div>
+      </div>
+
       <div style={{ marginBottom: 12 }}>
         <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Report (required -- IOLMaster/Lenstar printout, scanned reports)" />
       </div>
@@ -272,10 +286,6 @@ export default function BiometryWorkspace({ recordId }) {
       {!isMeasured && canEdit && (
         <div className="card">
           <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-check" style={{ color: 'var(--green)' }}></i> Mark as Measured</div>
-          <div style={{ marginBottom: 10 }}>
-            <label className="flbl">Technician remarks</label>
-            <input className="fi fi-sm" placeholder="e.g. Optical biometry unreliable due to dense cataract, A-Scan used as backup..." value={remarks} onChange={(e) => setRemarks(e.target.value)} />
-          </div>
           <div style={{ display: 'flex', gap: 8 }}>
             <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleMarkMeasured} disabled={saving}>
               <i className="ti ti-check"></i> Mark as Measured
diff --git a/app/(main)/biometry/actions.js b/app/(main)/biometry/actions.js
index 8c58052..db2c7dd 100644
--- a/app/(main)/biometry/actions.js
+++ b/app/(main)/biometry/actions.js
@@ -127,18 +127,18 @@ export async function getBiometryDetail(id) {
   return { record: data, recommendations: recommendations || [], isDoctor };
 }
 
-// Persists measurement readings without changing status -- technician
-// can leave and resume later. Once the record is Measured, this is
-// locked to Doctors only (correcting a finalized reading), same
-// boundary the workspace UI enforces.
-export async function saveBiometryDraft(id, measurements) {
+// Persists measurement readings (and notes) without changing status --
+// technician can leave and resume later. Once the record is Measured,
+// this is locked to Doctors only (correcting a finalized reading),
+// same boundary the workspace UI enforces.
+export async function saveBiometryDraft(id, measurements, notes) {
   const supabase = await createClient();
   const lockError = await assertBiometryEditable(supabase, id);
   if (lockError) return lockError;
 
   const { error } = await supabase
     .from('biometry_records')
-    .update({ measurements, updated_at: new Date().toISOString() })
+    .update({ measurements, verify_remarks: notes ?? null, updated_at: new Date().toISOString() })
     .eq('id', id);
   if (error) return { error: error.message };
   return { success: true };
diff --git a/app/(main)/print-templates/page.js b/app/(main)/print-templates/page.js
index 33c5b61..15e667d 100644
--- a/app/(main)/print-templates/page.js
+++ b/app/(main)/print-templates/page.js
@@ -68,6 +68,8 @@ PLACEHOLDER_REFERENCE.biometry_report = [
   'procedure_name', 'surgical_eye', 'verified_by_name', 'verified_by_regn_no',
   '{{#if hasReReadings}}...{{/if}}', '{{#each reSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
   '{{#if hasLeReadings}}...{{/if}}', '{{#each leSets}}...device, axl, k1, k2, acd, wtw...{{/each}}',
+  '{{#if hasRecommendations}}...{{/if}}', '{{#each recommendations}}...brandModel, rePower, lePower...{{/each}}',
+  '{{#if hasNotes}}...{{/if}}', 'notes',
 ];
 
 PLACEHOLDER_REFERENCE.discharge_summary = [
diff --git a/app/print-templates/actions.js b/app/print-templates/actions.js
index 3b7fcbf..fa41ce6 100644
--- a/app/print-templates/actions.js
+++ b/app/print-templates/actions.js
@@ -269,6 +269,31 @@ const DEFAULT_TEMPLATES = {
     </tr>
   </table>
 
+  <!-- IOL RECOMMENDATIONS -->
+  {{#if hasRecommendations}}
+  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">IOL Recommendations (from device printout)</div>
+  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px; font-size: 12px;">
+    <tr style="background: #e9edf2;">
+      <th style="border: 1px solid #999; padding: 7px; text-align: left;">Brand / Model</th>
+      <th style="border: 1px solid #999; padding: 7px; text-align: center;">RE Power</th>
+      <th style="border: 1px solid #999; padding: 7px; text-align: center;">LE Power</th>
+    </tr>
+    {{#each recommendations}}
+    <tr>
+      <td style="border: 1px solid #999; padding: 7px;">{{brandModel}}</td>
+      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{rePower}}</td>
+      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{lePower}}</td>
+    </tr>
+    {{/each}}
+  </table>
+  {{/if}}
+
+  <!-- NOTES -->
+  {{#if hasNotes}}
+  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">Notes</div>
+  <div style="border: 1px solid #999; border-radius: 6px; padding: 10px 14px; font-size: 12.5px; white-space: pre-wrap; margin-bottom: 18px;">{{notes}}</div>
+  {{/if}}
+
   <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
     <tr>
       <td style="width: 100%; text-align: right; font-size: 12px; vertical-align: bottom;">
@@ -699,8 +724,13 @@ const SAMPLE_BIOMETRY_RAW = {
       re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', wtw: '11.80' }],
       le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', wtw: '11.75' }],
     },
+    verify_remarks: 'Optical biometry unreliable on RE due to dense cataract -- Manual A-Scan cross-checked.',
   },
   verifiedBy: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
+  recommendations: [
+    { master_iol_catalog: { brand: 'Alcon', model: 'AcrySof IQ' }, re_power: '21.5', le_power: '21.0' },
+    { master_iol_catalog: { brand: 'Johnson & Johnson', model: 'Tecnis Eyhance' }, re_power: '21.5', le_power: '21.0' },
+  ],
 };
 
 // ── Renders the actual invoice HTML for a given invoiceId. Picks the
@@ -1345,10 +1375,16 @@ function buildBiometryReadingSets(sets) {
   }));
 }
 
-function buildBiometryReportContext(settings, { patient, visit, record, verifiedBy }) {
+function buildBiometryReportContext(settings, { patient, visit, record, verifiedBy, recommendations }) {
   const reSets = buildBiometryReadingSets(record.measurements?.re);
   const leSets = buildBiometryReadingSets(record.measurements?.le);
 
+  const recRows = (recommendations || []).map((r) => ({
+    brandModel: `${r.master_iol_catalog?.brand || ''} ${r.master_iol_catalog?.model || ''}`.trim() || '--',
+    rePower: r.re_power ?? '--',
+    lePower: r.le_power ?? '--',
+  }));
+
   const EYE_LABEL = { RE: 'Right Eye (RE / OD)', LE: 'Left Eye (LE / OS)', Both: 'Both Eyes (OU)', OD: 'Right Eye (RE / OD)', OS: 'Left Eye (LE / OS)', OU: 'Both Eyes (OU)' };
 
   return {
@@ -1378,6 +1414,12 @@ function buildBiometryReportContext(settings, { patient, visit, record, verified
     reSets,
     hasLeReadings: leSets.length > 0,
     leSets,
+
+    hasRecommendations: recRows.length > 0,
+    recommendations: recRows,
+
+    hasNotes: !!(record.verify_remarks && record.verify_remarks.trim()),
+    notes: record.verify_remarks || '',
   };
 }
 
@@ -1397,12 +1439,19 @@ export async function renderBiometryReportHtml(recordId) {
     verifiedBy = doc;
   }
 
+  const { data: recommendations } = await supabase
+    .from('biometry_iol_recommendations')
+    .select('*, master_iol_catalog(brand, model)')
+    .eq('biometry_record_id', recordId)
+    .order('created_at', { ascending: true });
+
   const settings = await getHospitalSettings();
   const context = buildBiometryReportContext(settings, {
     patient: record.visits?.patients || {},
     visit: record.visits,
     record,
     verifiedBy,
+    recommendations: recommendations || [],
   });
 
   const template = await getPrintTemplate('biometry_report');
PATCH_EOF

git apply --check /tmp/notes_and_print_fixes.patch
git apply /tmp/notes_and_print_fixes.patch
rm /tmp/notes_and_print_fixes.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Biometry print report: IOL Recommendations you add now actually appear on the printed report (brand/model + RE/LE power table) -- this was missing before, the print function never fetched them"
echo "  - Biometry workspace: new persistent 'Notes' field, always visible (not just before Mark as Measured), saved with every Save Draft / Save Correction"
echo "  - Biometry print report: Notes section added -- only shows on the report if something was actually typed in"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Biometry: fix IOL Recommendations missing from print report; add persistent Notes field that prints when filled"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
