#!/bin/bash
set -e

echo "==> Medical Fitness: deep-link straight to patient record, auto-close + auto-refresh on completion"

if [ ! -d "app/(main)/medical-fitness" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/medical-fitness not found here)."
  exit 1
fi

cat > /tmp/medical_fitness_deeplink_close.patch << 'PATCH_EOF'
diff --git a/app/(main)/medical-fitness/page.js b/app/(main)/medical-fitness/page.js
index 0998013..a470b27 100644
--- a/app/(main)/medical-fitness/page.js
+++ b/app/(main)/medical-fitness/page.js
@@ -1,6 +1,7 @@
 'use client';
 
-import { useState, useEffect, useCallback } from 'react';
+import { Suspense, useState, useEffect, useCallback } from 'react';
+import { useSearchParams } from 'next/navigation';
 import {
   getMedicalFitnessQueue, getMedicalFitnessHistory, getMedicalFitnessClearedToday, getMedicalFitnessDetail,
   getInvestigationMasterOptions, orderFitnessInvestigation, removeFitnessInvestigation,
@@ -278,6 +279,22 @@ export function WorkspaceTab({ referralId, onDone }) {
     refresh();
   }
 
+  // Opened as a deep link from Surgical Journey (a real opener window
+  // exists) -- signal the update back and close this tab so the person
+  // lands right back on Surgical Journey instead of switching tabs and
+  // manually refreshing. Returns true if it closed the tab (caller
+  // should skip its own post-save cleanup in that case). Opened
+  // normally from the sidebar (no opener), returns false so the
+  // caller falls through to its usual in-place refresh/navigation.
+  function notifyParentAndClose() {
+    if (typeof window !== 'undefined' && window.opener) {
+      window.opener.postMessage({ type: 'fitness-updated', referralId }, window.location.origin);
+      window.close();
+      return true;
+    }
+    return false;
+  }
+
   async function handleSaveDraft() {
     setError(''); setOkMsg('');
     setSavingDraft(true);
@@ -294,6 +311,7 @@ export function WorkspaceTab({ referralId, onDone }) {
     const result = await submitFitnessForm(referralId, form, 'Cleared', form.certification.notes);
     setSaving(false);
     if (result.error) { setError(result.error); return; }
+    if (notifyParentAndClose()) return;
     onDone();
   }
 
@@ -304,6 +322,7 @@ export function WorkspaceTab({ referralId, onDone }) {
     const result = await submitFitnessForm(referralId, form, 'Not Fit', form.certification.notes);
     setSaving(false);
     if (result.error) { setError(result.error); return; }
+    if (notifyParentAndClose()) return;
     onDone();
   }
 
@@ -315,6 +334,7 @@ export function WorkspaceTab({ referralId, onDone }) {
     const result = await submitFitnessForm(referralId, form, data.referral.status, form.certification.notes);
     setSaving(false);
     if (result.error) { setError(result.error); return; }
+    if (notifyParentAndClose()) return;
     setOkMsg('Updated.');
     setUnlocked(false);
     refresh();
@@ -654,15 +674,25 @@ export function WorkspaceTab({ referralId, onDone }) {
 }
 
 // ── PAGE: single SPA with client-side tab switching, matching Counselling ──
-export default function MedicalFitnessPage() {
+// Deep-linkable via ?referralId=... -- Surgical Journey's Medical
+// Fitness step links straight here with the referral's id so it opens
+// that patient's own record instead of dropping onto the Queue for a
+// manual pick. An already-decided referral opens read-only by default
+// (formEditable = isPending || unlocked, see WorkspaceTab above) --
+// same locked-until-unlocked treatment used in Biometry and IOL
+// Approval, so no separate "view mode" flag is needed here.
+function MedicalFitnessInner() {
+  const searchParams = useSearchParams();
+  const deepLinkReferralId = searchParams.get('referralId');
+
   const [queueRows, setQueueRows] = useState([]);
   const [clearedTodayRows, setClearedTodayRows] = useState([]);
   const [historyRows, setHistoryRows] = useState([]);
   const [loadingQueue, setLoadingQueue] = useState(true);
   const [loadingClearedToday, setLoadingClearedToday] = useState(true);
   const [loadingHistory, setLoadingHistory] = useState(true);
-  const [activeTab, setActiveTab] = useState('queue');
-  const [selectedReferralId, setSelectedReferralId] = useState(null);
+  const [activeTab, setActiveTab] = useState(deepLinkReferralId ? 'workspace' : 'queue');
+  const [selectedReferralId, setSelectedReferralId] = useState(deepLinkReferralId || null);
 
   const refreshQueue = useCallback(async () => {
     setQueueRows(await getMedicalFitnessQueue());
@@ -719,3 +749,11 @@ export default function MedicalFitnessPage() {
   );
 }
 
+export default function MedicalFitnessPage() {
+  return (
+    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
+      <MedicalFitnessInner />
+    </Suspense>
+  );
+}
+
diff --git a/app/(main)/surgical-journey/[id]/workspace.js b/app/(main)/surgical-journey/[id]/workspace.js
index 1fb81a2..92012c0 100644
--- a/app/(main)/surgical-journey/[id]/workspace.js
+++ b/app/(main)/surgical-journey/[id]/workspace.js
@@ -243,7 +243,7 @@ export default function Workspace({ caseId }) {
       {/* 6. MEDICAL FITNESS -- comes after the surgery date is booked
           (pre-anaesthesia clearance closer to the actual surgery date
           is more clinically useful than clearing weeks in advance). */}
-      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} num={6} />
+      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} num={6} refresh={refresh} />
 
       {/* 7. PAYMENT */}
       <Section num={7} color="var(--teal)" title="Payment" done={stepDone.payment} active={currentStep === 'payment'}>
@@ -304,9 +304,22 @@ export default function Workspace({ caseId }) {
 // Kept as a real doctor referral/review (same as Counselling), not a
 // self-certify checkbox -- clearing a patient for anaesthesia is a
 // genuine clinical judgment, not paperwork. Deep-links to the Medical
-// Fitness module for the actual review.
-function FitnessSection({ sc, fitnessReferral, onAction, active, num }) {
+// Fitness module for the actual review, opened as a real new tab
+// (window.opener intact) so it can signal back and close itself once
+// the review is submitted -- same pattern as IOL Approval.
+function FitnessSection({ sc, fitnessReferral, onAction, active, num, refresh }) {
   const cleared = sc.fitness_cleared || sc.fitness_required === false || fitnessReferral?.status === 'Cleared';
+
+  useEffect(() => {
+    function handleMessage(e) {
+      if (e.origin !== window.location.origin) return;
+      if (e.data?.type !== 'fitness-updated' || e.data.referralId !== fitnessReferral?.id) return;
+      refresh();
+    }
+    window.addEventListener('message', handleMessage);
+    return () => window.removeEventListener('message', handleMessage);
+  }, [fitnessReferral?.id, refresh]);
+
   if (sc.decision !== 'Accepted') {
     return (
       <Section num={num} color="var(--red)" title="Medical Fitness" done={false} active={active}>
@@ -323,18 +336,32 @@ function FitnessSection({ sc, fitnessReferral, onAction, active, num }) {
           <i className="ti ti-info-circle"></i> Will appear in the Medical Fitness module automatically once the OT date is booked.
         </div>
       ) : fitnessReferral.status === 'Pending Review' ? (
-        <span className="badge b-amber"><i className="ti ti-clock"></i> Awaiting doctor review (referred {new Date(fitnessReferral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}) -- <a href="/medical-fitness" style={{ color: 'var(--blue)', fontWeight: 600 }}>Open Medical Fitness &rarr;</a></span>
+        <div style={{ fontSize: 11.5 }}>
+          <span className="badge b-amber" style={{ marginBottom: 8 }}><i className="ti ti-clock"></i> Awaiting doctor review (referred {new Date(fitnessReferral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })})</span>
+          <div>
+            <button type="button" className="btn btn-sm btn-primary" onClick={() => openTab(`/medical-fitness?referralId=${fitnessReferral.id}`, `medical-fitness-${fitnessReferral.id}`)}>
+              <i className="ti ti-heart-rate-monitor"></i> Open Medical Fitness
+            </button>
+          </div>
+        </div>
       ) : fitnessReferral.status === 'Cleared' ? (
         <div>
           <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
           {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
+          <div style={{ marginTop: 8 }}>
+            <button type="button" className="btn btn-sm" onClick={() => openTab(`/medical-fitness?referralId=${fitnessReferral.id}`, `medical-fitness-${fitnessReferral.id}`)}>
+              <i className="ti ti-pencil"></i> Edit
+            </button>
+          </div>
         </div>
       ) : (
         <div>
           <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
           {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
-          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>
-            <i className="ti ti-info-circle"></i> Doctor can review again from the <a href="/medical-fitness" style={{ color: 'var(--blue)', fontWeight: 600 }}>Medical Fitness module</a>.
+          <div style={{ marginTop: 8 }}>
+            <button type="button" className="btn btn-sm" onClick={() => openTab(`/medical-fitness?referralId=${fitnessReferral.id}`, `medical-fitness-${fitnessReferral.id}`)}>
+              <i className="ti ti-pencil"></i> Review Again
+            </button>
           </div>
         </div>
       )}
PATCH_EOF

git apply --check /tmp/medical_fitness_deeplink_close.patch
git apply /tmp/medical_fitness_deeplink_close.patch
rm /tmp/medical_fitness_deeplink_close.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Surgical Journey > Medical Fitness step: 'Open Medical Fitness' now opens a real new tab, deep-linked straight to that patient's referral (no more landing on the Queue to pick manually)"
echo "  - Uses the same window.open()-based openTab helper as IOL Approval, so window.opener survives and the tab can signal back"
echo "  - On successful Clear / Not Fit / Update in that tab, it posts a message back and closes itself -- Surgical Journey picks it up and refreshes automatically, no manual refresh needed"
echo "  - Already-decided referrals (Cleared / Not Fit) open read-only by default (existing lock behavior in the module) with an Unlock button before anything becomes editable -- same protection Biometry and IOL Approval already have"
echo "  - Surgical Journey now also shows an Edit / Review Again button once a decision exists, using the same deep link"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Surgical Journey: Medical Fitness opens in new tab deep-linked to the patient record, auto-closes and refreshes parent on completion"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
