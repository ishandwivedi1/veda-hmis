#!/bin/bash
set -e

echo "==> Recovery & Discharge: doctor-style medication entry + tapering, lock/edit toggle, Discharged/Completed Today section"

if [ ! -d "app/(main)/ot-recovery" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/(main)/ot-recovery not found here)."
  exit 1
fi

cat > /tmp/recovery_meds_lock_discharged_today.patch << 'PATCH_EOF'
diff --git a/app/(main)/ot-recovery/actions.js b/app/(main)/ot-recovery/actions.js
index 1c163ff..4b0c847 100644
--- a/app/(main)/ot-recovery/actions.js
+++ b/app/(main)/ot-recovery/actions.js
@@ -2,18 +2,20 @@
 
 import { createClient } from '@/lib/supabase-server';
 import { DISCHARGE_ITEMS } from './constants';
-import { getDrugs } from '../master-data/actions';
+import { getDrugs, getDosageOptions } from '../master-data/actions';
 
-// Same Pharmacy drug list used in Financial Masters -- so post-op
-// medication is picked from the real catalog, not free text. Label
-// leads with Name (brand), not Salt Composition (generic) -- this is
-// what ends up stored as the medication name and printed on the
-// Discharge Summary.
+// Same Pharmacy drug list + dosage master used in the Doctor
+// (Consultation) module's prescription form -- so post-op medication
+// entry is the same experience, not a simpler one-off form. Keeps
+// drug_type_id and generic/strength so the workspace can filter dosage
+// options and power a type-ahead the same way Consultation does.
 export async function getDrugOptions() {
   const all = await getDrugs();
-  return all
-    .filter((d) => d.status === 'Active' && d.brand)
-    .map((d) => ({ id: d.id, label: `${d.brand}${d.strength ? ` ${d.strength}` : ''}${d.generic ? ` (${d.generic})` : ''}` }));
+  return all.filter((d) => d.status === 'Active' && d.brand);
+}
+
+export async function getMedDosageOptions() {
+  return getDosageOptions();
 }
 
 // Called from OT Intraop's "Hand Over to Recovery" -- creates the
@@ -111,12 +113,58 @@ export async function saveRecoveryFields(episodeId, values) {
   return { success: true };
 }
 
-// ── MEDICATIONS ──
-export async function addRecoveryMedication(episodeId, name, sig, reason) {
+// ── MEDICATIONS -- same structured Dosage/Frequency/Duration/Eye
+// entry (and tapering schedule support) as the Doctor module's
+// prescription form, instead of a single free-text "sig" field. `sig`
+// is still composed and stored on each row so existing consumers (the
+// Discharge Summary print template, the on-page list) keep working
+// unchanged. ──
+function composeSig(dosage, frequency, duration) {
+  return [dosage, frequency, duration && `x ${duration}`].filter(Boolean).join(' ');
+}
+
+export async function addRecoveryMedication(episodeId, values, reason) {
+  const supabase = await createClient();
+  if (!values.name?.trim()) return { error: 'Medicine name is required.' };
+  if (!values.dosage?.trim()) return { error: 'Dosage is required.' };
+  if (!values.frequency?.trim() || !values.duration?.trim()) return { error: 'Frequency and duration are required.' };
+  const { data: userData } = await supabase.auth.getUser();
+  const { error } = await supabase.from('recovery_medications').insert({
+    recovery_episode_id: episodeId,
+    name: values.name.trim(),
+    dosage: values.dosage, frequency: values.frequency, duration: values.duration, eye: values.eye || null,
+    sig: composeSig(values.dosage, values.frequency, values.duration),
+    reason: reason?.trim() || null,
+    added_by: userData?.user?.id || null,
+  });
+  if (error) return { error: error.message };
+  return { success: true };
+}
+
+// Tapering schedule -- same drug and dosage-per-administration across
+// steps as Consultation's tapering builder (the amount per dose stays
+// the same, only the frequency reduces over time), each step a
+// separate row sharing one taper_group_id.
+export async function addTaperedRecoveryMedication(episodeId, values, reason) {
   const supabase = await createClient();
-  if (!name?.trim() || !sig?.trim()) return { error: 'Medicine name and dose/frequency are required.' };
+  if (!values.name?.trim()) return { error: 'Medicine name is required.' };
+  if (!values.dosage?.trim()) return { error: 'Dosage is required.' };
+  const steps = (values.steps || []).filter((s) => s.frequency && s.duration);
+  if (steps.length < 2) return { error: 'A tapering schedule needs at least 2 steps.' };
+
   const { data: userData } = await supabase.auth.getUser();
-  const { error } = await supabase.from('recovery_medications').insert({ recovery_episode_id: episodeId, name: name.trim(), sig: sig.trim(), reason: reason?.trim() || null, added_by: userData?.user?.id || null });
+  const taperGroupId = crypto.randomUUID();
+  const rows = steps.map((s, i) => ({
+    recovery_episode_id: episodeId,
+    name: values.name.trim(),
+    dosage: values.dosage, frequency: s.frequency, duration: s.duration, eye: values.eye || null,
+    sig: composeSig(values.dosage, s.frequency, s.duration),
+    reason: reason?.trim() || null,
+    taper_group_id: taperGroupId, taper_step: i + 1,
+    added_by: userData?.user?.id || null,
+  }));
+
+  const { error } = await supabase.from('recovery_medications').insert(rows);
   if (error) return { error: error.message };
   return { success: true };
 }
@@ -128,6 +176,13 @@ export async function removeRecoveryMedication(id) {
   return { success: true };
 }
 
+export async function removeRecoveryTaperGroup(taperGroupId) {
+  const supabase = await createClient();
+  const { error } = await supabase.from('recovery_medications').delete().eq('taper_group_id', taperGroupId);
+  if (error) return { error: error.message };
+  return { success: true };
+}
+
 // ── DISCHARGE ──
 // The 4 suggested review dates (Day 1 / Week 1 / Month 1 / Final
 // Refraction) are a starting point, not a rule -- different surgeries
diff --git a/app/(main)/ot-recovery/workspace.js b/app/(main)/ot-recovery/workspace.js
index 8985caf..22ed986 100644
--- a/app/(main)/ot-recovery/workspace.js
+++ b/app/(main)/ot-recovery/workspace.js
@@ -3,7 +3,8 @@
 import { useState, useEffect, useCallback } from 'react';
 import {
   getRecoveryEpisodeDetail,
-  saveRecoveryFields, addRecoveryMedication, removeRecoveryMedication, confirmDischarge, getDrugOptions,
+  saveRecoveryFields, addRecoveryMedication, addTaperedRecoveryMedication, removeRecoveryMedication, removeRecoveryTaperGroup,
+  confirmDischarge, getDrugOptions, getMedDosageOptions,
 } from './actions';
 import { DISCHARGE_ITEMS } from './constants';
 import { openPrintPopup } from '@/lib/printPopup';
@@ -48,12 +49,32 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
   const [observations, setObservations] = useState('');
 
   const [checklist, setChecklist] = useState({});
-  const [medName, setMedName] = useState('');
-  const [drugOptions, setDrugOptions] = useState([]);
   const [dischargeDate, setDischargeDate] = useState(new Date().toISOString().slice(0, 10));
-  const [medSig, setMedSig] = useState('');
+
+  // Medication entry -- same structured Dosage/Frequency/Duration/Eye
+  // fields (plus tapering schedule builder) as the Doctor module's
+  // prescription form, instead of a single free-text field.
+  const [medName, setMedName] = useState('');
+  const [showMedSuggestions, setShowMedSuggestions] = useState(false);
+  const [showMedBrowseAll, setShowMedBrowseAll] = useState(false);
+  const [medDrugTypeId, setMedDrugTypeId] = useState(null);
+  const [medDosage, setMedDosage] = useState('');
+  const [medFrequency, setMedFrequency] = useState('BD');
+  const [medDuration, setMedDuration] = useState('1 week');
+  const [medEye, setMedEye] = useState('BE');
   const [medReason, setMedReason] = useState('');
   const [showMedForm, setShowMedForm] = useState(false);
+  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
+  const [taperSteps, setTaperSteps] = useState([
+    { frequency: 'QID', duration: '1 week' },
+    { frequency: 'TDS', duration: '1 week' },
+    { frequency: 'BD', duration: '1 week' },
+    { frequency: 'OD', duration: '1 week' },
+  ]);
+  const [drugOptions, setDrugOptions] = useState([]);
+  const [dosageOptions, setDosageOptions] = useState([]);
+
+  const [unlocked, setUnlocked] = useState(false);
 
   const [instructions, setInstructions] = useState('');
   const [dischargeNotes, setDischargeNotes] = useState('');
@@ -84,7 +105,7 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
     }
   }, [episodeId]);
 
-  useEffect(() => { refresh(); getDrugOptions().then(setDrugOptions); }, [episodeId, refresh]);
+  useEffect(() => { refresh(); getDrugOptions().then(setDrugOptions); getMedDosageOptions().then(setDosageOptions); }, [episodeId, refresh]);
 
   if (loadError) return <div className="msg-err">{loadError}</div>;
   if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;
@@ -93,9 +114,48 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
   const patient = sc.patients;
   const isDischarged = !!episode.discharge_date;
   const isClosed = !!episode.closure_status;
+  // Once discharged, the record is finalized and locked by default --
+  // same convention as Biometry, IOL Approval, and Medical Fitness.
+  // Explicit unlock is required before any field becomes editable
+  // again; a fully Closed episode (Post-Op) can never be unlocked here.
+  const isLocked = isDischarged && !isClosed && !unlocked;
+  const fieldsDisabled = isClosed || isLocked;
+
+  // Type-ahead for the medicine field -- same matching logic as
+  // Consultation's prescription form.
+  const medSuggestions = medName.trim().length > 0
+    ? drugOptions.filter((d) => d.brand && (
+        d.brand.toLowerCase().includes(medName.toLowerCase()) ||
+        (d.generic && d.generic.toLowerCase().includes(medName.toLowerCase()))
+      )).slice(0, 8)
+    : [];
+
+  function selectMedDrug(d) {
+    setMedName(d.brand);
+    setMedDrugTypeId(d.drug_type_id || null);
+    setMedDosage('');
+    setShowMedSuggestions(false);
+  }
+
+  // Group rows sharing a taper_group_id into one block, same as
+  // Consultation's prescription list -- so a tapering schedule renders
+  // and can be removed as one item, not N unrelated medication rows.
+  const medItems = [];
+  { const seen = new Set();
+    meds.forEach((m) => {
+      if (m.taper_group_id) {
+        if (seen.has(m.taper_group_id)) return;
+        seen.add(m.taper_group_id);
+        const steps = meds.filter((x) => x.taper_group_id === m.taper_group_id).sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
+        medItems.push({ type: 'taper', key: m.taper_group_id, steps });
+      } else {
+        medItems.push({ type: 'single', key: m.id, row: m });
+      }
+    });
+  }
 
   function toggleChecklistItem(key) {
-    if (isClosed) return;
+    if (fieldsDisabled) return;
     setChecklist((prev) => ({ ...prev, [key]: !prev[key] }));
   }
 
@@ -121,9 +181,29 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
 
   async function handleAddMedicine() {
     setError('');
-    const result = await addRecoveryMedication(episodeId, medName, medSig, medReason);
+    if (!medName.trim()) { setError('Drug name is required.'); return; }
+    const result = await addRecoveryMedication(episodeId, { name: medName, dosage: medDosage, frequency: medFrequency, duration: medDuration, eye: medEye }, medReason);
     if (result.error) { setError(result.error); return; }
-    setMedName(''); setMedSig(''); setMedReason(''); setShowMedForm(false);
+    setMedName(''); setMedDrugTypeId(null); setMedReason(''); setShowMedForm(false);
+    refresh();
+  }
+
+  function updateTaperStep(index, field, value) {
+    setTaperSteps((prev) => prev.map((s, i) => (i === index ? { ...s, [field]: value } : s)));
+  }
+  function addTaperStep() {
+    setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week' }]);
+  }
+  function removeTaperStep(index) {
+    setTaperSteps((prev) => prev.filter((_, i) => i !== index));
+  }
+  async function handleAddTaperSchedule() {
+    setError('');
+    if (!medName.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
+    if (!medDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
+    const result = await addTaperedRecoveryMedication(episodeId, { name: medName, dosage: medDosage, eye: medEye, steps: taperSteps }, medReason);
+    if (result.error) { setError(result.error); return; }
+    setMedName(''); setMedDosage(''); setMedDrugTypeId(null); setMedReason(''); setShowTaperBuilder(false);
     refresh();
   }
 
@@ -179,14 +259,33 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
       {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
       {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}
 
+      {isLocked && (
+        <div className="msg-info" style={{ background: 'var(--g100)', color: 'var(--g600)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
+          <i className="ti ti-lock"></i>
+          <span style={{ flex: 1 }}>This record is finalized (discharged) and locked for viewing.</span>
+          <button className="btn btn-sm" onClick={() => setUnlocked(true)}>
+            <i className="ti ti-lock-open"></i> Edit
+          </button>
+        </div>
+      )}
+      {isDischarged && !isClosed && unlocked && (
+        <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
+          <i className="ti ti-edit"></i>
+          <span style={{ flex: 1 }}>Editing a discharged record. Changes are saved immediately.</span>
+          <button className="btn btn-sm" onClick={() => { setUnlocked(false); refresh(); }}>
+            <i className="ti ti-lock"></i> Lock again
+          </button>
+        </div>
+      )}
+
       <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
         <div>
           {/* Surgical summary read-only */}
           <div className="card">
             <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i> Surgical Summary (read-only)</div>
             <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 10 }}>
-              <div><label className="flbl">Admission date</label><input type="date" className="fi fi-sm" value={admissionDate} onChange={(e) => setAdmissionDate(e.target.value)} disabled={isClosed} /></div>
-              <div><label className="flbl">Surgery date</label><input type="date" className="fi fi-sm" value={surgeryDate} onChange={(e) => setSurgeryDate(e.target.value)} disabled={isClosed} /></div>
+              <div><label className="flbl">Admission date</label><input type="date" className="fi fi-sm" value={admissionDate} onChange={(e) => setAdmissionDate(e.target.value)} disabled={fieldsDisabled} /></div>
+              <div><label className="flbl">Surgery date</label><input type="date" className="fi fi-sm" value={surgeryDate} onChange={(e) => setSurgeryDate(e.target.value)} disabled={fieldsDisabled} /></div>
               <div><label className="flbl">Discharge date</label><input type="date" className="fi fi-sm" value={isDischarged ? episode.discharge_date : dischargeDate} onChange={(e) => setDischargeDate(e.target.value)} disabled={isDischarged || isClosed} /></div>
             </div>
             <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Procedure</span><strong>{sc.procedure_name}</strong></div>
@@ -205,25 +304,25 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
           <div className="card">
             <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--teal)' }}></i> Recovery Assessment</div>
             <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
-              <div><label className="flbl">Recovery start</label><input type="time" className="fi fi-sm" value={recStart} onChange={(e) => setRecStart(e.target.value)} disabled={isClosed} /></div>
-              <div><label className="flbl">Recovery end</label><input type="time" className="fi fi-sm" value={recEnd} onChange={(e) => setRecEnd(e.target.value)} disabled={isClosed} /></div>
+              <div><label className="flbl">Recovery start</label><input type="time" className="fi fi-sm" value={recStart} onChange={(e) => setRecStart(e.target.value)} disabled={fieldsDisabled} /></div>
+              <div><label className="flbl">Recovery end</label><input type="time" className="fi fi-sm" value={recEnd} onChange={(e) => setRecEnd(e.target.value)} disabled={fieldsDisabled} /></div>
             </div>
             <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
-              <div><label className="flbl">Consciousness</label><select className="fi fi-sm" value={consciousness} onChange={(e) => setConsciousness(e.target.value)} disabled={isClosed}><option>Alert</option><option>Drowsy</option><option>Confused</option></select></div>
-              <div><label className="flbl">Pain</label><select className="fi fi-sm" value={pain} onChange={(e) => setPain(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Moderate</option><option>Severe</option></select></div>
-              <div><label className="flbl">Nausea</label><select className="fi fi-sm" value={nausea} onChange={(e) => setNausea(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Vomiting</option></select></div>
+              <div><label className="flbl">Consciousness</label><select className="fi fi-sm" value={consciousness} onChange={(e) => setConsciousness(e.target.value)} disabled={fieldsDisabled}><option>Alert</option><option>Drowsy</option><option>Confused</option></select></div>
+              <div><label className="flbl">Pain</label><select className="fi fi-sm" value={pain} onChange={(e) => setPain(e.target.value)} disabled={fieldsDisabled}><option>None</option><option>Mild</option><option>Moderate</option><option>Severe</option></select></div>
+              <div><label className="flbl">Nausea</label><select className="fi fi-sm" value={nausea} onChange={(e) => setNausea(e.target.value)} disabled={fieldsDisabled}><option>None</option><option>Mild</option><option>Vomiting</option></select></div>
             </div>
             <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
-              <div><label className="flbl">Eye dressing status</label><select className="fi fi-sm" value={dressing} onChange={(e) => setDressing(e.target.value)} disabled={isClosed}><option>Intact, dry</option><option>Slight ooze</option><option>Needs change</option></select></div>
-              <div><label className="flbl">Escalation required?</label><select className="fi fi-sm" value={escalation ? 'Yes' : 'No'} onChange={(e) => setEscalation(e.target.value === 'Yes')} disabled={isClosed}><option>No</option><option>Yes</option></select></div>
+              <div><label className="flbl">Eye dressing status</label><select className="fi fi-sm" value={dressing} onChange={(e) => setDressing(e.target.value)} disabled={fieldsDisabled}><option>Intact, dry</option><option>Slight ooze</option><option>Needs change</option></select></div>
+              <div><label className="flbl">Escalation required?</label><select className="fi fi-sm" value={escalation ? 'Yes' : 'No'} onChange={(e) => setEscalation(e.target.value === 'Yes')} disabled={fieldsDisabled}><option>No</option><option>Yes</option></select></div>
             </div>
             {escalation && (
               <div style={{ marginBottom: 8 }}>
                 <label className="flbl">Escalation reason</label>
-                <input className="fi fi-sm" value={escalationReason} onChange={(e) => setEscalationReason(e.target.value)} disabled={isClosed} placeholder="Document reason for escalation..." />
+                <input className="fi fi-sm" value={escalationReason} onChange={(e) => setEscalationReason(e.target.value)} disabled={fieldsDisabled} placeholder="Document reason for escalation..." />
               </div>
             )}
-            <textarea className="fi fi-sm" rows={2} value={observations} onChange={(e) => setObservations(e.target.value)} disabled={isClosed} placeholder="Clinical observations / immediate concerns..." />
+            <textarea className="fi fi-sm" rows={2} value={observations} onChange={(e) => setObservations(e.target.value)} disabled={fieldsDisabled} placeholder="Clinical observations / immediate concerns..." />
           </div>
 
           {/* Discharge checklist */}
@@ -233,7 +332,7 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
               <span className={`badge ${mandatoryDone ? 'b-green' : 'b-gray'}`}>{Math.round((mandatoryChecked / mandatoryTotal) * 100)}%</span>
             </div>
             {DISCHARGE_ITEMS.map((item) => (
-              <div key={item.key} onClick={() => toggleChecklistItem(item.key)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: isClosed ? 'default' : 'pointer', background: checklist[item.key] ? 'var(--green-lt)' : '#fff', opacity: item.mandatory ? 1 : 0.85 }}>
+              <div key={item.key} onClick={() => toggleChecklistItem(item.key)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: fieldsDisabled ? 'default' : 'pointer', background: checklist[item.key] ? 'var(--green-lt)' : '#fff', opacity: item.mandatory ? 1 : 0.85 }}>
                 <div style={{ width: 18, height: 18, borderRadius: 4, background: checklist[item.key] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checklist[item.key] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checklist[item.key] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                 <span>{item.label} {!item.mandatory && <span style={{ fontSize: 10, color: 'var(--g400)' }}>(optional)</span>}</span>
               </div>
@@ -244,36 +343,143 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
         <div>
           {/* Medications */}
           <div className="card">
-            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Post-operative Medication Plan</div>
-            {meds.map((m) => (
-              <div key={m.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
-                <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i>
-                <span style={{ flex: 1 }}><strong>{m.name}</strong> -- {m.sig}</span>
-                {!isClosed && <button onClick={() => removeRecoveryMedication(m.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
-              </div>
+            <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Post-operative Medication Plan</div>
+            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
+              Same drug catalog, dosage, frequency, and tapering options as the Doctor module's prescription form.
+            </div>
+            {medItems.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No medications added yet.</div>}
+            {medItems.map((item) => (
+              item.type === 'single' ? (
+                <div key={item.key} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
+                  <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i>
+                  <span style={{ flex: 1 }}><strong>{item.row.name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration}{item.row.eye ? ` -- ${item.row.eye}` : ''}</span>
+                  {!fieldsDisabled && <button onClick={() => removeRecoveryMedication(item.row.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
+                </div>
+              ) : (
+                <div key={item.key} style={{ padding: '6px 8px', background: 'var(--purple-lt)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
+                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
+                    <strong>{item.steps[0].name}</strong> -- {item.steps[0].dosage}{item.steps[0].eye ? ` -- ${item.steps[0].eye}` : ''}
+                    <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering</span>
+                    {!fieldsDisabled && <button onClick={() => removeRecoveryTaperGroup(item.key).then(refresh)} style={{ marginLeft: 'auto', border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
+                  </div>
+                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>
+                    {item.steps.map((s, i) => (
+                      <span key={s.id}>{i > 0 && ' -> '}{s.frequency} x {s.duration}</span>
+                    ))}
+                    <span style={{ marginLeft: 6, color: 'var(--g500)' }}>, then stop</span>
+                  </div>
+                </div>
+              )
             ))}
-            {meds.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No medications added yet.</div>}
-            {!isClosed && (
-              <>
+
+            {!fieldsDisabled && (
+              <div style={{ marginTop: 8 }}>
                 {!showMedForm ? (
-                  <button className="btn btn-sm btn-primary" style={{ marginTop: 8 }} onClick={() => setShowMedForm(true)}><i className="ti ti-plus"></i> Add / modify medicine</button>
+                  <button className="btn btn-sm btn-primary" onClick={() => setShowMedForm(true)}><i className="ti ti-plus"></i> Add / modify medicine</button>
                 ) : (
-                  <div style={{ marginTop: 8 }}>
+                  <div>
+                    <div style={{ position: 'relative', marginBottom: 6 }}>
+                      <input
+                        className="fi fi-sm" style={{ width: '100%' }}
+                        placeholder="Type to search medicines, or enter a new name"
+                        value={medName}
+                        onChange={(e) => { setMedName(e.target.value); setMedDrugTypeId(null); setShowMedSuggestions(true); }}
+                        onFocus={() => setShowMedSuggestions(true)}
+                        onBlur={() => setTimeout(() => setShowMedSuggestions(false), 150)}
+                      />
+                      {showMedSuggestions && medName.trim().length > 0 && (
+                        <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 6px 16px rgba(0,0,0,.12)', maxHeight: 200, overflowY: 'auto', marginTop: 3 }}>
+                          {medSuggestions.length > 0 ? medSuggestions.map((d) => (
+                            <div key={d.id} onMouseDown={() => selectMedDrug(d)} style={{ padding: '7px 10px', cursor: 'pointer', fontSize: 12, borderBottom: '1px solid var(--g100)' }}>
+                              <strong>{d.brand}</strong>{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}
+                            </div>
+                          )) : (
+                            <div style={{ padding: '7px 10px', fontSize: 11.5, color: 'var(--g500)' }}>
+                              No match.{' '}
+                              <button className="btn btn-sm" style={{ padding: '1px 6px', fontSize: 10.5 }} onMouseDown={() => { setShowMedBrowseAll(true); setShowMedSuggestions(false); }}>Browse full list</button>
+                              {' '}or keep typing for free text.
+                            </div>
+                          )}
+                        </div>
+                      )}
+                      {showMedBrowseAll && (
+                        <select className="fi fi-sm" style={{ marginTop: 6, width: '100%' }} value="" onChange={(e) => {
+                          if (!e.target.value) return;
+                          const picked = drugOptions.find((d) => d.brand === e.target.value);
+                          if (picked) selectMedDrug(picked);
+                          setShowMedBrowseAll(false);
+                        }}>
+                          <option value="">-- Browse full Pharmacy master --</option>
+                          {drugOptions.map((d) => <option key={d.id} value={d.brand}>{d.brand}{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
+                        </select>
+                      )}
+                    </div>
+
                     <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
-                      <select className="fi fi-sm" value={medName} onChange={(e) => setMedName(e.target.value)}>
-                        <option value="">-- Select medicine --</option>
-                        {drugOptions.map((d) => <option key={d.id} value={d.label}>{d.label}</option>)}
+                      <select className="fi fi-sm" value={medDosage} onChange={(e) => setMedDosage(e.target.value)}>
+                        <option value="">-- Dosage --</option>
+                        {(medDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === medDrugTypeId) : []).map((o) => (
+                          <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
+                        ))}
+                        {!medDrugTypeId && (
+                          <>
+                            <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
+                          </>
+                        )}
+                      </select>
+                      <select className="fi fi-sm" value={medEye} onChange={(e) => setMedEye(e.target.value)}>
+                        <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                       </select>
-                      <input className="fi fi-sm" value={medSig} onChange={(e) => setMedSig(e.target.value)} placeholder="Dose/Freq/Duration" />
                     </div>
-                    <input className="fi fi-sm" value={medReason} onChange={(e) => setMedReason(e.target.value)} placeholder="Reason for change (if modifying existing plan)..." style={{ marginBottom: 6 }} />
+
+                    {!showTaperBuilder ? (
+                      <>
+                        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
+                          <select className="fi fi-sm" value={medFrequency} onChange={(e) => setMedFrequency(e.target.value)}>
+                            <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
+                          </select>
+                          <select className="fi fi-sm" value={medDuration} onChange={(e) => setMedDuration(e.target.value)}>
+                            <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
+                          </select>
+                        </div>
+                        <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginBottom: 6 }} onClick={() => setShowTaperBuilder(true)}>
+                          <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
+                        </button>
+                      </>
+                    ) : (
+                      <div style={{ marginBottom: 6, padding: 10, background: 'var(--purple-lt)', borderRadius: 8 }}>
+                        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--purple)', marginBottom: 6 }}>
+                          <i className="ti ti-chart-line"></i> Tapering -- uses the Drug, Dosage &amp; Eye above; frequency reduces step by step
+                        </div>
+                        {taperSteps.map((s, i) => (
+                          <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 5 }}>
+                            <span style={{ fontSize: 10.5, color: 'var(--g500)', width: 14 }}>{i + 1}.</span>
+                            <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 90 }}>
+                              <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
+                            </select>
+                            <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 100 }}>
+                              <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option>
+                            </select>
+                            {taperSteps.length > 2 && (
+                              <button className="btn btn-sm" style={{ padding: '1px 6px' }} onClick={() => removeTaperStep(i)}><i className="ti ti-x" style={{ color: 'var(--red)' }}></i></button>
+                            )}
+                          </div>
+                        ))}
+                        <button className="btn btn-sm" onClick={addTaperStep}><i className="ti ti-plus"></i> Add Step</button>
+                      </div>
+                    )}
+
+                    <input className="fi fi-sm" value={medReason} onChange={(e) => setMedReason(e.target.value)} placeholder="Reason for change (if modifying existing plan)..." style={{ marginBottom: 6, width: '100%' }} />
+
                     <div style={{ display: 'flex', gap: 6 }}>
-                      <button className="btn btn-sm btn-primary" onClick={handleAddMedicine}>Add</button>
-                      <button className="btn btn-sm" onClick={() => setShowMedForm(false)}>Cancel</button>
+                      <button className="btn btn-sm btn-primary" onClick={showTaperBuilder ? handleAddTaperSchedule : handleAddMedicine}>
+                        {showTaperBuilder ? 'Save Tapering Schedule' : 'Add'}
+                      </button>
+                      <button className="btn btn-sm" onClick={() => { setShowMedForm(false); setShowTaperBuilder(false); }}>Cancel</button>
                     </div>
                   </div>
                 )}
-              </>
+              </div>
             )}
           </div>
 
@@ -281,17 +487,17 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
           <div className="card">
             <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--teal)' }}></i> Discharge Instructions</div>
             <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
-              <span className="badge b-teal" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.cataract)}>Standard cataract template</span>
-              <span className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.glaucoma)}>Glaucoma surgery template</span>
+              <span className="badge b-teal" style={{ cursor: 'pointer' }} onClick={() => !fieldsDisabled && setInstructions(TEMPLATES.cataract)}>Standard cataract template</span>
+              <span className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !fieldsDisabled && setInstructions(TEMPLATES.glaucoma)}>Glaucoma surgery template</span>
             </div>
-            <textarea className="fi fi-sm" rows={4} value={instructions} onChange={(e) => setInstructions(e.target.value)} disabled={isClosed} placeholder="Eye drop schedule, eye shield usage, activity restrictions, warning symptoms..." />
+            <textarea className="fi fi-sm" rows={4} value={instructions} onChange={(e) => setInstructions(e.target.value)} disabled={fieldsDisabled} placeholder="Eye drop schedule, eye shield usage, activity restrictions, warning symptoms..." />
           </div>
 
           {/* Discharge notes */}
           <div className="card">
             <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--indigo)' }}></i> Discharge Notes (Doctor)</div>
             <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Clinical condition at discharge -- distinct from the patient-facing instructions above.</div>
-            <textarea className="fi fi-sm" rows={3} value={dischargeNotes} onChange={(e) => setDischargeNotes(e.target.value)} disabled={isClosed} placeholder="e.g. Eye quiet, cornea clear, IOP within normal limits..." />
+            <textarea className="fi fi-sm" rows={3} value={dischargeNotes} onChange={(e) => setDischargeNotes(e.target.value)} disabled={fieldsDisabled} placeholder="e.g. Eye quiet, cornea clear, IOP within normal limits..." />
           </div>
 
           {/* Follow-up schedule */}
@@ -342,23 +548,36 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
       {!isClosed && (
         <div style={{ background: '#0f172a', borderRadius: 12, padding: '10px 14px', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginTop: 14 }}>
           <span style={{ fontSize: 11, color: '#64748b', fontWeight: 600 }}>ACTIONS:</span>
-          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSave} disabled={saving}>
-            <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save'}
-          </button>
-          {!isDischarged && (
-            <button className="btn btn-sm" style={{ background: 'rgba(34,197,94,.2)', color: '#86efac', borderColor: 'rgba(34,197,94,.4)', fontWeight: 700 }} onClick={handleDischarge} disabled={!mandatoryDone}>
-              <i className="ti ti-door-exit"></i> Discharge
+          {isLocked ? (
+            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={() => setUnlocked(true)}>
+              <i className="ti ti-lock-open"></i> Unlock to Edit
             </button>
-          )}
-          {isDischarged && (
-            <button onClick={() => openPrintPopup(`/discharge-summary-print/${episodeId}`)} className="btn btn-sm" style={{ background: 'rgba(15,118,110,.2)', color: '#5eead4', borderColor: 'rgba(15,118,110,.4)' }}>
-              <i className="ti ti-printer"></i> Print Discharge Summary
-            </button>
-          )}
-          {isDischarged && (
-            <span className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default', fontWeight: 700 }}>
-              <i className="ti ti-circle-check"></i> Discharged
-            </span>
+          ) : (
+            <>
+              <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSave} disabled={saving}>
+                <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save'}
+              </button>
+              {!isDischarged && (
+                <button className="btn btn-sm" style={{ background: 'rgba(34,197,94,.2)', color: '#86efac', borderColor: 'rgba(34,197,94,.4)', fontWeight: 700 }} onClick={handleDischarge} disabled={!mandatoryDone}>
+                  <i className="ti ti-door-exit"></i> Discharge
+                </button>
+              )}
+              {isDischarged && (
+                <button onClick={() => openPrintPopup(`/discharge-summary-print/${episodeId}`)} className="btn btn-sm" style={{ background: 'rgba(15,118,110,.2)', color: '#5eead4', borderColor: 'rgba(15,118,110,.4)' }}>
+                  <i className="ti ti-printer"></i> Print Discharge Summary
+                </button>
+              )}
+              {isDischarged && (
+                <span className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default', fontWeight: 700 }}>
+                  <i className="ti ti-circle-check"></i> Discharged
+                </span>
+              )}
+              {isDischarged && unlocked && (
+                <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={() => { setUnlocked(false); refresh(); }}>
+                  <i className="ti ti-lock"></i> Lock again
+                </button>
+              )}
+            </>
           )}
         </div>
       )}
diff --git a/app/(main)/surgical-journey/actions.js b/app/(main)/surgical-journey/actions.js
index 78ca6bb..d40cdbd 100644
--- a/app/(main)/surgical-journey/actions.js
+++ b/app/(main)/surgical-journey/actions.js
@@ -184,31 +184,36 @@ export async function setTreatmentInstructions(caseId, instructions) {
 // done (set the moment Intraoperative Management's Surgery Complete is
 // submitted) -- the patient isn't actually through the journey until
 // Recovery confirms discharge. This resolves, for a batch of case ids
-// already known to be status='Completed', which of them also have a
-// discharge_date recorded -- those are the only ones that should
-// actually drop out of the Active list.
-async function getDischargedCaseIds(supabase, completedCaseIds) {
-  if (completedCaseIds.length === 0) return new Set();
+// already known to be status='Completed', each one's discharge_date
+// (or undefined if not yet discharged) so callers can bucket cases into
+// Active / Discharged Today / History exactly like the Dashboard vs
+// History split used elsewhere (OT Intraop, Recovery, Medical Fitness).
+async function getDischargeDatesByCase(supabase, completedCaseIds) {
+  if (completedCaseIds.length === 0) return {};
   const { data: schedules } = await supabase
     .from('ot_schedule')
     .select('id, surgical_case_id')
     .in('surgical_case_id', completedCaseIds);
   const scheduleIds = (schedules || []).map((s) => s.id);
-  if (scheduleIds.length === 0) return new Set();
+  if (scheduleIds.length === 0) return {};
   const scheduleToCase = Object.fromEntries((schedules || []).map((s) => [s.id, s.surgical_case_id]));
   const { data: episodes } = await supabase
     .from('recovery_episodes')
     .select('ot_schedule_id, discharge_date')
     .in('ot_schedule_id', scheduleIds)
     .not('discharge_date', 'is', null);
-  return new Set((episodes || []).map((e) => scheduleToCase[e.ot_schedule_id]).filter(Boolean));
+  const byCase = {};
+  (episodes || []).forEach((e) => {
+    const caseId = scheduleToCase[e.ot_schedule_id];
+    if (caseId) byCase[caseId] = e.discharge_date;
+  });
+  return byCase;
 }
 
-// Every open surgical case (any staff member -- a small setup doesn't
-// have per-doctor case ownership walls). "Open" = not Cancelled, and
-// not a Completed case that's also been discharged (see
-// getDischargedCaseIds above) -- a case whose surgery finished but
-// whose patient hasn't been discharged yet still belongs here.
+// Still genuinely in progress: not Cancelled, and not a Completed case
+// that's also been discharged (whether today or earlier) -- a case
+// whose surgery finished but whose patient hasn't been discharged yet
+// still belongs here.
 export async function getMyActiveSurgicalCases() {
   const supabase = await createClient();
   const { data, error } = await supabase
@@ -220,17 +225,38 @@ export async function getMyActiveSurgicalCases() {
   const cases = data || [];
 
   const completedIds = cases.filter((c) => c.status === 'Completed').map((c) => c.id);
-  const dischargedIds = await getDischargedCaseIds(supabase, completedIds);
+  const dischargeDates = await getDischargeDatesByCase(supabase, completedIds);
+
+  return cases.filter((c) => !(c.status === 'Completed' && dischargeDates[c.id]));
+}
+
+// Discharged TODAY -- kept visible on the front page instead of
+// vanishing into History the instant discharge happens, same
+// Dashboard/History convention as OT Intraop and Recovery. Moves to
+// History once the day rolls over.
+export async function getDischargedTodaySurgicalCases() {
+  const supabase = await createClient();
+  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
+  const { data, error } = await supabase
+    .from('surgical_cases')
+    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
+    .eq('status', 'Completed')
+    .order('created_at', { ascending: false });
+  if (error) return [];
+  const cases = data || [];
+
+  const completedIds = cases.map((c) => c.id);
+  const dischargeDates = await getDischargeDatesByCase(supabase, completedIds);
 
-  return cases.filter((c) => !(c.status === 'Completed' && dischargedIds.has(c.id)));
+  return cases.filter((c) => dischargeDates[c.id] === todayIst);
 }
 
-// Cancelled cases, plus Completed cases that have actually been
-// discharged -- the counterpart to getMyActiveSurgicalCases above, for
-// the History tab so a case doesn't just vanish once it drops off
-// Active.
+// Cancelled cases (any time), plus Completed cases discharged BEFORE
+// today -- the counterpart to the two functions above, so a case
+// doesn't just vanish once it drops off Active / Discharged Today.
 export async function getCompletedSurgicalCases() {
   const supabase = await createClient();
+  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
   const { data, error } = await supabase
     .from('surgical_cases')
     .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
@@ -240,9 +266,9 @@ export async function getCompletedSurgicalCases() {
   const cases = data || [];
 
   const completedIds = cases.filter((c) => c.status === 'Completed').map((c) => c.id);
-  const dischargedIds = await getDischargedCaseIds(supabase, completedIds);
+  const dischargeDates = await getDischargeDatesByCase(supabase, completedIds);
 
-  return cases.filter((c) => c.status === 'Cancelled' || (c.status === 'Completed' && dischargedIds.has(c.id)));
+  return cases.filter((c) => c.status === 'Cancelled' || (c.status === 'Completed' && dischargeDates[c.id] && dischargeDates[c.id] < todayIst));
 }
 
 // Patients whose decision is "Wants Time to Decide" and haven't
diff --git a/app/(main)/surgical-journey/page.js b/app/(main)/surgical-journey/page.js
index eec3c5d..6fd22b3 100644
--- a/app/(main)/surgical-journey/page.js
+++ b/app/(main)/surgical-journey/page.js
@@ -2,7 +2,7 @@
 
 import { useState, useEffect, useCallback } from 'react';
 import { useRouter } from 'next/navigation';
-import { getMyActiveSurgicalCases, getAwaitingReturnCases, getCompletedSurgicalCases, recordManualReminder } from './actions';
+import { getMyActiveSurgicalCases, getAwaitingReturnCases, getDischargedTodaySurgicalCases, getCompletedSurgicalCases, recordManualReminder } from './actions';
 
 const STAGE_LABEL = {
   'Pending Workup': 'Working Up',
@@ -117,8 +117,10 @@ export default function SurgicalJourneyPage() {
   const [activeTab, setActiveTab] = useState('active');
   const [cases, setCases] = useState([]);
   const [awaiting, setAwaiting] = useState([]);
+  const [dischargedToday, setDischargedToday] = useState([]);
   const [history, setHistory] = useState([]);
   const [loading, setLoading] = useState(true);
+  const [loadingDischargedToday, setLoadingDischargedToday] = useState(true);
   const [loadingHistory, setLoadingHistory] = useState(true);
   const [reminderFor, setReminderFor] = useState(null);
   const router = useRouter();
@@ -128,12 +130,16 @@ export default function SurgicalJourneyPage() {
     setAwaiting(await getAwaitingReturnCases());
     setLoading(false);
   }, []);
+  const refreshDischargedToday = useCallback(async () => {
+    setDischargedToday(await getDischargedTodaySurgicalCases());
+    setLoadingDischargedToday(false);
+  }, []);
   const refreshHistory = useCallback(async () => {
     setHistory(await getCompletedSurgicalCases());
     setLoadingHistory(false);
   }, []);
 
-  useEffect(() => { refresh(); refreshHistory(); }, [refresh, refreshHistory]);
+  useEffect(() => { refresh(); refreshDischargedToday(); refreshHistory(); }, [refresh, refreshDischargedToday, refreshHistory]);
 
   const proceeding = cases.filter((c) => c.decision !== 'Wants Time to Decide' && c.decision !== 'Declined');
 
@@ -211,6 +217,33 @@ export default function SurgicalJourneyPage() {
               <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No active surgical cases right now.</div>
             )}
           </div>
+
+          <div className="card" style={{ marginBottom: 0 }}>
+            <div className="card-title" style={{ marginBottom: 4 }}>
+              <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Discharged / Completed Today
+              <span className="badge b-green" style={{ marginLeft: 8 }}>{dischargedToday.length}</span>
+            </div>
+            <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>Moves to Completed / History tomorrow -- still open here today for reference.</div>
+            {loadingDischargedToday && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Loading...</div>}
+            {!loadingDischargedToday && dischargedToday.map((c) => (
+              <div key={c.id} onClick={() => router.push(`/surgical-journey/${c.id}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
+                <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
+                  {c.patients?.first_name?.charAt(0)}
+                </div>
+                <div style={{ flex: 1 }}>
+                  <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
+                  <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>Discharged</span>
+                  <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
+                    {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye}{c.master_packages ? ` -- ${c.master_packages.name}` : ''}
+                  </div>
+                </div>
+                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
+              </div>
+            ))}
+            {!loadingDischargedToday && dischargedToday.length === 0 && (
+              <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nobody discharged yet today.</div>
+            )}
+          </div>
         </>
       )}
 
PATCH_EOF

git apply --check /tmp/recovery_meds_lock_discharged_today.patch
git apply /tmp/recovery_meds_lock_discharged_today.patch
rm /tmp/recovery_meds_lock_discharged_today.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - DB migration already applied directly via Supabase MCP to BOTH projects (production flzysyzhaecaqbmdcuao and training ffaddzpwnbizhvhujlse) -- recovery_medications got dosage/frequency/duration/eye/taper_group_id/taper_step columns. Nothing to run manually for this."
echo "  - Post-op Medication Plan in Recovery & Discharge now uses the SAME entry experience as the Doctor module: drug type-ahead + browse-all fallback, dosage pulled from the same master list per drug type, Frequency/Duration/Eye dropdowns, and an 'Add as Tapering Schedule instead' builder with per-step frequency/duration -- tapering schedules display and remove as one grouped block, same as Consultation"
echo "  - Discharged records are now locked by default (view-only) with an explicit 'Edit' / 'Unlock to Edit' button before any field becomes editable again -- same convention as Biometry, IOL Approval, and Medical Fitness. A closed Post-Op episode still cannot be unlocked."
echo "  - Surgical Journey front page: new 'Discharged / Completed Today' card (between Active Cases and the tab boundary) -- a case discharged today stays visible there instead of disappearing immediately; moves into the 'Completed / History' tab once the day rolls over, matching the Dashboard/History convention already used in OT Intraop and Recovery"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Recovery & Discharge: doctor-module-matching medication entry with tapering support, lock/unlock on discharge, and a new Discharged/Completed Today section on Surgical Journey"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
