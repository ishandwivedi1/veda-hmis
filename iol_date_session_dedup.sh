#!/bin/bash
set -e

echo "==> IOL Surgery Date & Order: rename, reorder (date on top), remove duplicate session picker"

if [ ! -d "app/(main)/surgical-journey" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/surgical-journey not found here)."
  exit 1
fi

cat > /tmp/iol_date_session_dedup.patch << 'PATCH_EOF'
diff --git a/app/(main)/surgical-journey/[id]/workspace.js b/app/(main)/surgical-journey/[id]/workspace.js
index e89ab86..1fb81a2 100644
--- a/app/(main)/surgical-journey/[id]/workspace.js
+++ b/app/(main)/surgical-journey/[id]/workspace.js
@@ -14,7 +14,7 @@ import {
   selectPackage, changePackage, updatePackageDiscount, getPackagesForCase,
   setDecision, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
 } from '@/app/(main)/counselling/actions';
-import { getOTAvailability, rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';
+import { rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';
 import { openPopup, openTab } from '@/lib/popup';
 
 const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };
@@ -756,25 +756,20 @@ function PackageDecisionSection({ sc, onAction, active }) {
 }
 
 // ── 4. IOL PROCUREMENT + DATE + BOOK SLOT ──────────────────────────
+// Date+session picking lives entirely in the OT Calendar popup (picks
+// both together, posts back via postMessage) -- so there is no
+// separate session picker here anymore. Having one here too used to
+// mean picking the session twice for the same booking.
 function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, num }) {
   const [iolNotes, setIolNotesLocal] = useState(sc.iol_order_notes || '');
   const [surgeons, setSurgeons] = useState([]);
   const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
   const [date, setDate] = useState('');
-  const [sessions, setSessions] = useState([]);
   const [sessionId, setSessionId] = useState('');
   const [sessionName, setSessionName] = useState('');
-  const [loadingSessions, setLoadingSessions] = useState(false);
 
   useEffect(() => { getSurgeons().then(setSurgeons); }, []);
 
-  useEffect(() => {
-    setSessionId('');
-    if (!date) { setSessions([]); return; }
-    setLoadingSessions(true);
-    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
-  }, [date]);
-
   // The date+session picker lives in the OT Schedule module's own
   // Calendar tab (prior bookings visible there, one place instead of
   // duplicating a calendar here) -- opened as a real popup window, and
@@ -805,19 +800,14 @@ function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, n
 
   if (otSchedule) {
     return (
-      <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done active={active}>
-        <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
-          <input className="fi fi-sm" style={{ flex: 1 }} value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
-          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
-        </div>
-
+      <Section num={num} color="var(--teal)" title="IOL Surgery Date &amp; Order" done active={active}>
         {!rescheduling ? (
-          <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, fontSize: 12.5, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
+          <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, fontSize: 12.5, marginBottom: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
             <span><i className="ti ti-calendar-check"></i> Booked -- {new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}, {otSchedule.master_ot_sessions?.name} session</span>
             {otSchedule.status === 'Scheduled' && <button className="btn btn-sm" onClick={() => setRescheduling(true)}>Reschedule</button>}
           </div>
         ) : (
-          <div>
+          <div style={{ marginBottom: 10 }}>
             <div style={{ marginBottom: 8 }}>
               {date ? (
                 <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', fontSize: 12.5 }}>
@@ -830,23 +820,6 @@ function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, n
                 </button>
               )}
             </div>
-            {date && (
-              <div style={{ marginBottom: 8 }}>
-                <label className="flbl">Session</label>
-                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
-                  {loadingSessions ? <span style={{ fontSize: 12, color: 'var(--g400)' }}>Checking...</span> : sessions.map((s) => {
-                    const full = s.remaining <= 0;
-                    return (
-                      <button key={s.session_id} disabled={full} className="btn btn-sm"
-                        style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
-                        onClick={() => setSessionId(s.session_id)}>
-                        {s.name} ({s.remaining} left)
-                      </button>
-                    );
-                  })}
-                </div>
-              </div>
-            )}
             <div style={{ display: 'flex', gap: 8 }}>
               <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for rescheduling..." value={rescheduleReason} onChange={(e) => setRescheduleReason(e.target.value)} />
               <button
@@ -864,20 +837,17 @@ function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, n
             </div>
           </div>
         )}
-      </Section>
-    );
-  }
 
-  return (
-    <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done={false} defaultOpen={readyGateMet} active={active}>
-      <div style={{ marginBottom: 12 }}>
-        <label className="flbl">IOL Order Notes</label>
         <div style={{ display: 'flex', gap: 8 }}>
-          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Ordered Alcon monofocal +21D from XYZ Optics, expected Friday"' value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
+          <input className="fi fi-sm" style={{ flex: 1 }} value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
           <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
         </div>
-      </div>
+      </Section>
+    );
+  }
 
+  return (
+    <Section num={num} color="var(--teal)" title="IOL Surgery Date &amp; Order" done={false} defaultOpen={readyGateMet} active={active}>
       {!readyGateMet && (
         <div style={{ fontSize: 11.5, color: 'var(--g400)', marginBottom: 10 }}>
           <i className="ti ti-info-circle"></i> Waiting on Patient Decision first.
@@ -886,15 +856,6 @@ function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, n
 
       {readyGateMet && (
         <>
-          <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 8, marginBottom: 10 }}>
-            <div>
-              <label className="flbl">Surgeon</label>
-              <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
-                <option value="">--</option>
-                {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
-              </select>
-            </div>
-          </div>
           <div style={{ marginBottom: 10 }}>
             <label className="flbl">Date</label>
             {date ? (
@@ -908,29 +869,23 @@ function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, n
               </button>
             )}
           </div>
-          {date && (
-            <div style={{ marginBottom: 10 }}>
-              <label className="flbl">Session</label>
-              {loadingSessions ? (
-                <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
-              ) : (
-                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
-                  {sessions.map((s) => {
-                    const full = s.remaining <= 0;
-                    return (
-                      <button
-                        key={s.session_id} disabled={full} className="btn btn-sm"
-                        style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
-                        onClick={() => setSessionId(s.session_id)}
-                      >
-                        {s.name} ({s.remaining} left)
-                      </button>
-                    );
-                  })}
-                </div>
-              )}
+
+          <div style={{ marginBottom: 10 }}>
+            <label className="flbl">Surgeon</label>
+            <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
+              <option value="">--</option>
+              {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
+            </select>
+          </div>
+
+          <div style={{ marginBottom: 12 }}>
+            <label className="flbl">IOL Order Notes</label>
+            <div style={{ display: 'flex', gap: 8 }}>
+              <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Ordered Alcon monofocal +21D from XYZ Optics, expected Friday"' value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
+              <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
             </div>
-          )}
+          </div>
+
           <button
             className="btn btn-primary btn-sm"
             disabled={!date || !sessionId}
PATCH_EOF

git apply --check /tmp/iol_date_session_dedup.patch
git apply /tmp/iol_date_session_dedup.patch
rm /tmp/iol_date_session_dedup.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - Section renamed: 'IOL Order & Surgery Date' -> 'IOL Surgery Date & Order'"
echo "  - Date field now appears first (Date -> Surgeon -> IOL Order Notes -> Give This Date)"
echo "  - Removed the duplicate session picker in Surgical Journey -- session is already picked together with the date inside the OT Calendar popup and posted back via postMessage; the local re-pick buttons here were asking for the same choice twice"
echo "  - Same cleanup applied to the reschedule flow (booked-case view)"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Surgical Journey: rename to IOL Surgery Date & Order, date field on top, remove duplicate session picker (session now comes solely from OT Calendar)"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
