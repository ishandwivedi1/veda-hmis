#!/bin/bash
set -e

echo "==> Intraoperative Management: remove IOL expiry date, mark serial required, remove recovery destination, make post-op instructions optional"

if [ ! -d "app/(main)/ot-intraop" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/ot-intraop not found here)."
  exit 1
fi

cat > /tmp/intraop_implant_recovery_fields.patch << 'PATCH_EOF'
diff --git a/app/(main)/ot-intraop/actions.js b/app/(main)/ot-intraop/actions.js
index f7aa4d1..d813c49 100644
--- a/app/(main)/ot-intraop/actions.js
+++ b/app/(main)/ot-intraop/actions.js
@@ -357,7 +357,6 @@ export async function completeSurgery(otScheduleId, surgicalCaseId, values) {
     // skipImplant when there's no biometry plan at all.
     if (!values.skipImplant) return { error: 'VAL-OT-003: Implant power and serial/batch number are mandatory.' };
   }
-  if (!values.recoveryInstructions) return { error: 'VAL-OT-005: Recovery handover (post-operative instructions) must be documented.' };
   if (!values.surgicalOutcome) return { error: 'VAL-OT-005: Surgical outcome must be recorded.' };
   const needsRemarks = ['Converted Procedure', 'Procedure Deferred', 'Procedure Abandoned'].includes(values.surgicalOutcome);
   if (needsRemarks && !values.outcomeRemarks) {
diff --git a/app/(main)/ot-intraop/workspace.js b/app/(main)/ot-intraop/workspace.js
index ab1ab19..325cf78 100644
--- a/app/(main)/ot-intraop/workspace.js
+++ b/app/(main)/ot-intraop/workspace.js
@@ -995,10 +995,7 @@ export default function Workspace({ otScheduleId, onBack, restrictTab }) {
 
             <div style={{ borderTop: '1px dashed var(--g200)', paddingTop: 10 }}>
               <div style={{ fontSize: 10.5, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 6 }}>Serial / Batch (from the implanted unit's label)</div>
-              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
-                <div><label className="flbl">Serial / Batch number</label><input className="fi fi-sm" value={imSerial} onChange={(e) => setImSerial(e.target.value)} disabled={isReadOnly} /></div>
-                <div><label className="flbl">Expiry date</label><input type="date" className="fi fi-sm" value={imExpiry} onChange={(e) => setImExpiry(e.target.value)} disabled={isReadOnly} /></div>
-              </div>
+              <div><label className="flbl">Serial / Batch number<sup style={{ color: 'var(--red)', marginLeft: 2 }}>*</sup></label><input className="fi fi-sm" value={imSerial} onChange={(e) => setImSerial(e.target.value)} disabled={isReadOnly} /></div>
             </div>
           </div>
 
@@ -1021,12 +1018,12 @@ export default function Workspace({ otScheduleId, onBack, restrictTab }) {
           {/* Recovery */}
           <div className="card" style={{ marginBottom: 0 }}>
             <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-bed" style={{ color: 'var(--teal)' }}></i> Recovery Handover</div>
-            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
-              <div><label className="flbl">Recovery destination</label><select className="fi fi-sm" value={recoveryDest} onChange={(e) => setRecoveryDest(e.target.value)} disabled={isReadOnly}><option>Recovery Bay 1</option><option>Recovery Bay 2</option><option>Day Care Ward</option></select></div>
-              <div><label className="flbl">Required monitoring</label><input className="fi fi-sm" value={recoveryMonitor} onChange={(e) => setRecoveryMonitor(e.target.value)} disabled={isReadOnly} placeholder="e.g. Vitals q15min x1hr" /></div>
+            <div style={{ marginBottom: 8 }}>
+              <label className="flbl">Required monitoring</label>
+              <input className="fi fi-sm" value={recoveryMonitor} onChange={(e) => setRecoveryMonitor(e.target.value)} disabled={isReadOnly} placeholder="e.g. Vitals q15min x1hr" />
             </div>
             <div style={{ marginBottom: 8 }}>
-              <label className="flbl">Post-operative instructions</label>
+              <label className="flbl">Post-operative instructions <span style={{ fontWeight: 400, color: 'var(--g400)', fontSize: 11 }}>(optional)</span></label>
               <textarea className="fi fi-sm" rows={2} value={recoveryInstructions} onChange={(e) => setRecoveryInstructions(e.target.value)} disabled={isReadOnly} placeholder="e.g. Eye shield overnight. Moxifloxacin QID..." />
             </div>
             <input className="fi fi-sm" value={recoveryConcerns} onChange={(e) => setRecoveryConcerns(e.target.value)} disabled={isReadOnly} placeholder="Immediate concerns (if any)..." />
@@ -1082,7 +1079,7 @@ export default function Workspace({ otScheduleId, onBack, restrictTab }) {
             <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Completion Checklist</div>
             {[
               { label: 'Implant information complete', done: biometryPlans.length === 0 || !!(imPower && imSerial) },
-              { label: 'Recovery handover documented', done: !!recoveryInstructions },
+              { label: 'Recovery handover documented (optional)', done: !!recoveryInstructions },
             ].map((it) => (
               <div key={it.label} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                 <i className={`ti ${it.done ? 'ti-circle-check' : 'ti-circle'}`} style={{ color: it.done ? 'var(--green)' : 'var(--g300)' }}></i> {it.label}
PATCH_EOF

git apply --check /tmp/intraop_implant_recovery_fields.patch
git apply /tmp/intraop_implant_recovery_fields.patch
rm /tmp/intraop_implant_recovery_fields.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Implant section: removed the Expiry date field entirely"
echo "  - Serial / Batch number label now shows a small red asterisk in superscript to indicate it's required (it already was required server-side -- VAL-OT-003 -- this just makes that visible)"
echo "  - Recovery Handover: removed the Recovery Destination dropdown"
echo "  - Post-operative instructions is now explicitly labeled (optional), and the server-side completeSurgery validation that required it (VAL-OT-005) has been removed -- Save Draft, Surgery Complete, and Save Changes (correction) all work now without it filled in"
echo "  - Completion checklist on the right updated to reflect Recovery handover as optional, not a blocking requirement"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Intraoperative Management: remove implant expiry date field, mark serial number required (asterisk), remove recovery destination, make post-op instructions optional (drop VAL-OT-005 server validation)"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
