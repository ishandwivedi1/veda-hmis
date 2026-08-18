#!/bin/bash
set -e

echo "==> Payment (Advance), Patient Check-In, Intraoperative Management: new-tab + auto-close + auto-refresh"

if [ ! -d "app/(main)/surgical-journey" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/surgical-journey not found here)."
  exit 1
fi

cat > /tmp/advance_checkin_intraop_newtab.patch << 'PATCH_EOF'
diff --git a/app/(main)/ot-intraop/workspace.js b/app/(main)/ot-intraop/workspace.js
index 33e85b2..ab1ab19 100644
--- a/app/(main)/ot-intraop/workspace.js
+++ b/app/(main)/ot-intraop/workspace.js
@@ -249,6 +249,16 @@ export default function Workspace({ otScheduleId, onBack, restrictTab }) {
     addLog('OT Check-In completed');
     setOk('Check-in complete -- patient confirmed in OT.');
     await refresh();
+    // Opened as a deep link from Surgical Journey (a real opener window
+    // exists) -- signal completion back and close this tab instead of
+    // sending staff to the Dashboard in what would otherwise become an
+    // orphaned tab. Same close-on-complete pattern as IOL Approval,
+    // Medical Fitness, and Advance collection.
+    if (restrictTab === 'checkin' && typeof window !== 'undefined' && window.opener) {
+      window.opener.postMessage({ type: 'checkin-updated', otScheduleId }, window.location.origin);
+      window.close();
+      return;
+    }
     // The Patient Check-In module doesn't have an Intraoperative tab to
     // switch to -- send staff back to the queue instead, where the case
     // now shows as checked-in and ready for the OT team.
@@ -377,6 +387,15 @@ export default function Workspace({ otScheduleId, onBack, restrictTab }) {
     });
     if (result.error) { setError(result.error); return; }
     clearInterval(timerRef.current);
+    // Opened as a deep link from Surgical Journey (a real opener window
+    // exists) -- signal completion back and close this tab. Same
+    // close-on-complete pattern as IOL Approval, Medical Fitness, and
+    // Patient Check-In above.
+    if (typeof window !== 'undefined' && window.opener) {
+      window.opener.postMessage({ type: 'intraop-updated', otScheduleId }, window.location.origin);
+      window.close();
+      return;
+    }
     if (wasAlreadyCompleted) {
       addLog('INTRAOP RECORD CORRECTED -- changes saved after completion');
       setOk('Changes saved.');
diff --git a/app/(main)/payments/advance/advance-tab.js b/app/(main)/payments/advance/advance-tab.js
index 8d5b034..8260ed9 100644
--- a/app/(main)/payments/advance/advance-tab.js
+++ b/app/(main)/payments/advance/advance-tab.js
@@ -8,7 +8,7 @@ import TodaysVisitsWidget from '../todays-visits-widget';
 const ADVANCE_TYPES = ['Surgery Advance', 'General Advance', 'Package Advance', 'Other'];
 const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
 
-const RETURN_LABELS = { 'ot-intraop': 'Intraoperative Management', 'patient-checkin': 'Patient Check-In' };
+const RETURN_LABELS = { 'ot-intraop': 'Intraoperative Management', 'patient-checkin': 'Patient Check-In', 'surgical-journey': 'Surgical Journey' };
 
 export default function AdvanceTab() {
   const searchParams = useSearchParams();
@@ -139,12 +139,22 @@ export default function AdvanceTab() {
   }
 
   // Collecting via a returnTo link (e.g. from OT Dashboard) means the
-  // natural next step is back there, not sitting on this form.
+  // natural next step is back there, not sitting on this form. When
+  // opened as a real new tab from Surgical Journey (window.opener
+  // present, see the openTab-based Collect Advance button there),
+  // signal the collection back and close this tab instead of
+  // redirecting -- same close-on-complete pattern as IOL Approval and
+  // Medical Fitness.
   useEffect(() => {
     if (!success || !returnTo) return;
+    if (returnTo === 'surgical-journey' && typeof window !== 'undefined' && window.opener) {
+      window.opener.postMessage({ type: 'advance-collected', patientId: selectedPatient?.id }, window.location.origin);
+      const timer = setTimeout(() => window.close(), 900);
+      return () => clearTimeout(timer);
+    }
     const timer = setTimeout(() => router.push(`/${returnTo}`), 2500);
     return () => clearTimeout(timer);
-  }, [success, returnTo, router]);
+  }, [success, returnTo, router, selectedPatient]);
 
   return (
     <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
@@ -164,10 +174,18 @@ export default function AdvanceTab() {
             <div style={{ marginTop: 10, display: 'flex', gap: 8, alignItems: 'center' }}>
               {returnTo ? (
                 <>
-                  <button className="btn btn-sm btn-primary" onClick={() => router.push(`/${returnTo}`)}>
+                  <button
+                    className="btn btn-sm btn-primary"
+                    onClick={() => {
+                      if (returnTo === 'surgical-journey' && typeof window !== 'undefined' && window.opener) { window.close(); return; }
+                      router.push(`/${returnTo}`);
+                    }}
+                  >
                     <i className="ti ti-arrow-left"></i> Back to {RETURN_LABELS[returnTo] || returnTo}
                   </button>
-                  <span style={{ fontSize: 11, color: 'var(--g400)' }}>Returning automatically...</span>
+                  <span style={{ fontSize: 11, color: 'var(--g400)' }}>
+                    {returnTo === 'surgical-journey' && typeof window !== 'undefined' && window.opener ? 'Closing automatically...' : 'Returning automatically...'}
+                  </span>
                 </>
               ) : (
                 <button className="btn btn-sm" onClick={reset}>Collect another advance</button>
diff --git a/app/(main)/surgical-journey/[id]/workspace.js b/app/(main)/surgical-journey/[id]/workspace.js
index 92012c0..16bf837 100644
--- a/app/(main)/surgical-journey/[id]/workspace.js
+++ b/app/(main)/surgical-journey/[id]/workspace.js
@@ -165,6 +165,24 @@ export default function Workspace({ caseId }) {
 
   useEffect(() => { refresh(); }, [refresh]);
 
+  // Advance collection, Patient Check-In, and Intraoperative Management
+  // are all opened as real new tabs via openTab() (see the buttons
+  // below) so window.opener survives -- each of those tabs signals
+  // back here and closes itself once its own step is actually done,
+  // same close-on-complete pattern as IOL Approval and Medical
+  // Fitness. This single listener covers all three message types.
+  useEffect(() => {
+    function handleMessage(e) {
+      if (e.origin !== window.location.origin) return;
+      const t = e.data?.type;
+      if (t === 'advance-collected' && e.data.patientId === data?.case?.patients?.id) refresh();
+      else if (t === 'checkin-updated' && e.data.otScheduleId === data?.otSchedule?.id) refresh();
+      else if (t === 'intraop-updated' && e.data.otScheduleId === data?.otSchedule?.id) refresh();
+    }
+    window.addEventListener('message', handleMessage);
+    return () => window.removeEventListener('message', handleMessage);
+  }, [data?.case?.patients?.id, data?.otSchedule?.id, refresh]);
+
   function flash(fn) {
     return async (...args) => {
       setError(''); setOk('');
@@ -278,7 +296,7 @@ export default function Workspace({ caseId }) {
                 </div>
                 <button
                   className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }}
-                  onClick={() => router.push(`/payments/advance?patientId=${patient.id}&amount=${Math.max(0, netPackageAmount - advanceBalance)}&returnTo=surgical-journey`)}
+                  onClick={() => openTab(`/payments/advance?patientId=${patient.id}&amount=${Math.max(0, netPackageAmount - advanceBalance)}&returnTo=surgical-journey`, `advance-${patient.id}`)}
                 >
                   <i className="ti ti-cash"></i> Collect Advance
                 </button>
@@ -289,7 +307,7 @@ export default function Workspace({ caseId }) {
       </Section>
 
       {/* 8. PATIENT CHECK-IN */}
-      <PatientCheckinSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} paymentDone={stepDone.payment} router={router} active={currentStep === 'checkin'} num={8} />
+      <PatientCheckinSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} paymentDone={stepDone.payment} active={currentStep === 'checkin'} num={8} />
 
       {/* 9. INTRAOPERATIVE MANAGEMENT */}
       <IntraopManagementSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'intraop'} num={9} />
@@ -933,7 +951,7 @@ function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, n
 }
 
 // ── 7. PATIENT CHECK-IN (live status, deep-link only) ──
-function PatientCheckinSection({ otSchedule, checkinCompletedAt, paymentDone, router, active, num }) {
+function PatientCheckinSection({ otSchedule, checkinCompletedAt, paymentDone, active, num }) {
   if (!paymentDone) {
     return (
       <Section num={num} color="var(--g400)" title="Patient Check-In" done={false} active={active}>
@@ -951,11 +969,11 @@ function PatientCheckinSection({ otSchedule, checkinCompletedAt, paymentDone, ro
     if (done) {
       status = 'Checked in';
       color = 'var(--green)';
-      action = { label: 'View in Patient Check-In', onClick: () => router.push(`/patient-checkin?otScheduleId=${otSchedule.id}`) };
+      action = { label: 'View in Patient Check-In', onClick: () => openTab(`/patient-checkin?otScheduleId=${otSchedule.id}`, `checkin-${otSchedule.id}`) };
     } else {
       status = `Scheduled -- ${new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })} -- not yet checked in`;
       color = 'var(--blue)';
-      action = { label: 'Open in Patient Check-In', onClick: () => router.push(`/patient-checkin?otScheduleId=${otSchedule.id}`) };
+      action = { label: 'Open in Patient Check-In', onClick: () => openTab(`/patient-checkin?otScheduleId=${otSchedule.id}`, `checkin-${otSchedule.id}`) };
     }
   }
 
@@ -988,7 +1006,7 @@ function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpis
     if (otSchedule.status === 'In Progress') {
       status = 'In surgery now';
       color = 'var(--red)';
-      action = { label: 'Continue in Intraoperative Management', onClick: () => router.push(`/ot-intraop?otScheduleId=${otSchedule.id}`) };
+      action = { label: 'Continue in Intraoperative Management', onClick: () => openTab(`/ot-intraop?otScheduleId=${otSchedule.id}`, `intraop-${otSchedule.id}`) };
     } else if (otSchedule.status === 'Completed') {
       if (recoveryEpisode && !recoveryEpisode.discharge_date) {
         status = 'Surgery done -- in Recovery';
@@ -1005,7 +1023,7 @@ function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpis
     } else {
       status = 'Checked in -- ready for OT';
       color = 'var(--blue)';
-      action = { label: 'Open in Intraoperative Management', onClick: () => router.push(`/ot-intraop?otScheduleId=${otSchedule.id}`) };
+      action = { label: 'Open in Intraoperative Management', onClick: () => openTab(`/ot-intraop?otScheduleId=${otSchedule.id}`, `intraop-${otSchedule.id}`) };
     }
   }
 
PATCH_EOF

git apply --check /tmp/advance_checkin_intraop_newtab.patch
git apply /tmp/advance_checkin_intraop_newtab.patch
rm /tmp/advance_checkin_intraop_newtab.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Collect Advance: opens in a new tab (was same-tab redirect); on successful collection it posts back and closes itself instead of redirecting -- Surgical Journey refreshes automatically"
echo "  - Patient Check-In: 'Open/View in Patient Check-In' opens in a new tab, deep-linked to that case; completing check-in closes the tab and refreshes Surgical Journey"
echo "  - Intraoperative Management: 'Open/Continue in Intraoperative Management' opens in a new tab, deep-linked to that case; completing surgery closes the tab and refreshes Surgical Journey"
echo "  - 'Open in Recovery' / 'Open in Post-Op' links are unchanged (still same-tab) -- those are separate modules without a deep-link entry point today, out of scope for this pass"
echo "  - Notes & Follow-up Calls: left as-is -- it is an inline field directly on the Surgical Journey page, not a separate module, so there is no tab to open/close there"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Surgical Journey: Advance collection, Patient Check-In, and Intraoperative Management open in new tabs, auto-close and refresh parent on completion"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
