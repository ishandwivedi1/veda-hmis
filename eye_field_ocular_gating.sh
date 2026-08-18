#!/bin/bash
set -e

echo "==> Eye field hidden for non-ocular medicines (tablets, capsules, syrups, injections) in Doctor + Discharge modules"

if [ ! -d "app/consultation" ]; then
  echo "ERROR: run this from the root of the veda-hmis repo (app/consultation not found here)."
  exit 1
fi

cat > /tmp/eye_field_ocular_gating.patch << 'PATCH_EOF'
diff --git a/app/(main)/master-data/actions.js b/app/(main)/master-data/actions.js
index 2c18fe1..39a86da 100644
--- a/app/(main)/master-data/actions.js
+++ b/app/(main)/master-data/actions.js
@@ -177,6 +177,17 @@ export async function updateDrugType(id, oldValues, values) {
   if (oldValues.name !== name) await logMasterAudit(supabase, 'master_drug_types', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
   return { success: true };
 }
+// Whether this drug type is applied to the eye (drops, ointments, gels
+// -- the Eye field in Prescription applies) vs taken systemically
+// (tablets, capsules, syrups, injections -- no eye makes sense, so the
+// field is skipped entirely rather than forcing a meaningless choice).
+// This is what the Doctor and Discharge medication forms key off of.
+export async function updateDrugTypeOcular(id, isOcular) {
+  const supabase = await createClient();
+  const { error } = await supabase.from('master_drug_types').update({ is_ocular: isOcular }).eq('id', id);
+  if (error) return { error: error.message };
+  return { success: true };
+}
 export async function deleteDrugType(id, code) {
   const supabase = await createClient();
   return deleteMasterRecord(supabase, 'master_drug_types', id, code);
@@ -552,7 +563,7 @@ export async function deleteSurgery(id, code) {
 // ── DRUGS ──
 export async function getDrugs() {
   const supabase = await createClient();
-  const { data } = await supabase.from('master_drugs').select('*, master_drug_types(id, name)').order('generic');
+  const { data } = await supabase.from('master_drugs').select('*, master_drug_types(id, name, is_ocular)').order('generic');
   return data || [];
 }
 // Drugs (Pharmacy tab) -- fixed "DRG" prefix, 3-digit sequence, same
diff --git a/app/(main)/master-data/financial/page.js b/app/(main)/master-data/financial/page.js
index 580af94..ec360d6 100644
--- a/app/(main)/master-data/financial/page.js
+++ b/app/(main)/master-data/financial/page.js
@@ -7,7 +7,7 @@ import {
   getPackages, addPackage, updatePackage, deletePackage,
   getPackageLineItems, addPackageLineItem, removePackageLineItem,
   getDrugs, addDrug, updateDrug, deleteDrug,
-  getDrugTypes, addDrugType, updateDrugType, deleteDrugType,
+  getDrugTypes, addDrugType, updateDrugType, updateDrugTypeOcular, deleteDrugType,
   getDosageOptions, addDosageOption, removeDosageOption,
   getVendorsMaster, addVendorMaster, updateVendorMaster, deleteVendorMaster,
   getSurgeries,
@@ -445,7 +445,7 @@ export default function FinancialMastersPage() {
               {showTypesPanel && (
                 <div style={{ marginTop: 12 }}>
                   <div className="msg-info" style={{ marginBottom: 12 }}>
-                    <i className="ti ti-info-circle"></i> Each type&apos;s dosage options are what shows up in the doctor&apos;s Prescription dosage dropdown when a drug of that type is selected -- e.g. &quot;Apply thin layer&quot; for Eye Ointment instead of &quot;1 drop&quot;.
+                    <i className="ti ti-info-circle"></i> Each type&apos;s dosage options are what shows up in the doctor&apos;s Prescription dosage dropdown when a drug of that type is selected -- e.g. &quot;Apply thin layer&quot; for Eye Ointment instead of &quot;1 drop&quot;. The &quot;Eye medication&quot; toggle controls whether Prescription/Discharge medication forms ask for an Eye (RE/LE/BE) -- turn it off for tablets, capsules, syrups, injections, and anything else taken systemically.
                   </div>
                   <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
                     <input className="fi" style={{ maxWidth: 260 }} placeholder="New type name (e.g. Suspension)" value={newTypeName} onChange={(e) => setNewTypeName(e.target.value)} />
@@ -463,6 +463,10 @@ export default function FinancialMastersPage() {
                           onBlur={(e) => handleRenameType(t, e.target.value)}
                         />
                         <span style={{ fontSize: 11, color: 'var(--g400)', fontFamily: 'monospace' }}>{t.code}</span>
+                        <label style={{ display: 'flex', alignItems: 'center', gap: 5, fontSize: 11.5, color: 'var(--g600)', cursor: 'pointer' }} title="Whether this type is applied to the eye (drops, ointments) -- controls whether Prescription/Discharge medication forms ask for Eye">
+                          <input type="checkbox" checked={!!t.is_ocular} onChange={(e) => updateDrugTypeOcular(t.id, e.target.checked).then(refresh)} />
+                          Eye medication
+                        </label>
                         <span style={{ marginLeft: 'auto' }}><StatusToggle record={t} table="master_drug_types" onUpdate={refresh} /></span>
                       </div>
                       {expandedTypeId === t.id && (
diff --git a/app/(main)/ot-recovery/workspace.js b/app/(main)/ot-recovery/workspace.js
index 22ed986..eb2902e 100644
--- a/app/(main)/ot-recovery/workspace.js
+++ b/app/(main)/ot-recovery/workspace.js
@@ -62,6 +62,7 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
   const [medFrequency, setMedFrequency] = useState('BD');
   const [medDuration, setMedDuration] = useState('1 week');
   const [medEye, setMedEye] = useState('BE');
+  const [medIsOcular, setMedIsOcular] = useState(true);
   const [medReason, setMedReason] = useState('');
   const [showMedForm, setShowMedForm] = useState(false);
   const [showTaperBuilder, setShowTaperBuilder] = useState(false);
@@ -133,6 +134,9 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
   function selectMedDrug(d) {
     setMedName(d.brand);
     setMedDrugTypeId(d.drug_type_id || null);
+    // Same logic as Consultation's prescription form -- tablets,
+    // capsules, syrups, and injections aren't applied to an eye.
+    setMedIsOcular(d.master_drug_types?.is_ocular !== false);
     setMedDosage('');
     setShowMedSuggestions(false);
   }
@@ -182,9 +186,9 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
   async function handleAddMedicine() {
     setError('');
     if (!medName.trim()) { setError('Drug name is required.'); return; }
-    const result = await addRecoveryMedication(episodeId, { name: medName, dosage: medDosage, frequency: medFrequency, duration: medDuration, eye: medEye }, medReason);
+    const result = await addRecoveryMedication(episodeId, { name: medName, dosage: medDosage, frequency: medFrequency, duration: medDuration, eye: medIsOcular ? medEye : null }, medReason);
     if (result.error) { setError(result.error); return; }
-    setMedName(''); setMedDrugTypeId(null); setMedReason(''); setShowMedForm(false);
+    setMedName(''); setMedDrugTypeId(null); setMedIsOcular(true); setMedReason(''); setShowMedForm(false);
     refresh();
   }
 
@@ -201,9 +205,9 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
     setError('');
     if (!medName.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
     if (!medDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
-    const result = await addTaperedRecoveryMedication(episodeId, { name: medName, dosage: medDosage, eye: medEye, steps: taperSteps }, medReason);
+    const result = await addTaperedRecoveryMedication(episodeId, { name: medName, dosage: medDosage, eye: medIsOcular ? medEye : null, steps: taperSteps }, medReason);
     if (result.error) { setError(result.error); return; }
-    setMedName(''); setMedDosage(''); setMedDrugTypeId(null); setMedReason(''); setShowTaperBuilder(false);
+    setMedName(''); setMedDosage(''); setMedDrugTypeId(null); setMedIsOcular(true); setMedReason(''); setShowTaperBuilder(false);
     refresh();
   }
 
@@ -383,7 +387,7 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
                         className="fi fi-sm" style={{ width: '100%' }}
                         placeholder="Type to search medicines, or enter a new name"
                         value={medName}
-                        onChange={(e) => { setMedName(e.target.value); setMedDrugTypeId(null); setShowMedSuggestions(true); }}
+                        onChange={(e) => { setMedName(e.target.value); setMedDrugTypeId(null); setMedIsOcular(true); setShowMedSuggestions(true); }}
                         onFocus={() => setShowMedSuggestions(true)}
                         onBlur={() => setTimeout(() => setShowMedSuggestions(false), 150)}
                       />
@@ -415,7 +419,7 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
                       )}
                     </div>
 
-                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
+                    <div style={{ display: 'grid', gridTemplateColumns: medIsOcular ? '1fr 1fr' : '1fr', gap: 6, marginBottom: 6 }}>
                       <select className="fi fi-sm" value={medDosage} onChange={(e) => setMedDosage(e.target.value)}>
                         <option value="">-- Dosage --</option>
                         {(medDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === medDrugTypeId) : []).map((o) => (
@@ -427,10 +431,15 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
                           </>
                         )}
                       </select>
-                      <select className="fi fi-sm" value={medEye} onChange={(e) => setMedEye(e.target.value)}>
-                        <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
-                      </select>
+                      {medIsOcular && (
+                        <select className="fi fi-sm" value={medEye} onChange={(e) => setMedEye(e.target.value)}>
+                          <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
+                        </select>
+                      )}
                     </div>
+                    {!medIsOcular && (
+                      <div style={{ fontSize: 10, color: 'var(--g400)', marginBottom: 6 }}><i className="ti ti-info-circle"></i> {medName} is not applied to the eye -- no Eye field needed.</div>
+                    )}
 
                     {!showTaperBuilder ? (
                       <>
@@ -449,7 +458,7 @@ export default function Workspace({ episodeId, onBack, onUpdate }) {
                     ) : (
                       <div style={{ marginBottom: 6, padding: 10, background: 'var(--purple-lt)', borderRadius: 8 }}>
                         <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--purple)', marginBottom: 6 }}>
-                          <i className="ti ti-chart-line"></i> Tapering -- uses the Drug, Dosage &amp; Eye above; frequency reduces step by step
+                          <i className="ti ti-chart-line"></i> Tapering -- uses the Drug &amp; Dosage{medIsOcular ? ' & Eye' : ''} above; frequency reduces step by step
                         </div>
                         {taperSteps.map((s, i) => (
                           <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 5 }}>
diff --git a/app/consultation/[id]/consultation-form.js b/app/consultation/[id]/consultation-form.js
index 55fbbb3..45bfdef 100644
--- a/app/consultation/[id]/consultation-form.js
+++ b/app/consultation/[id]/consultation-form.js
@@ -159,6 +159,7 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
   const [rxFrequency, setRxFrequency] = useState('BD');
   const [rxDuration, setRxDuration] = useState('1 week');
   const [rxEye, setRxEye] = useState('BE');
+  const [rxIsOcular, setRxIsOcular] = useState(true);
 
   // Investigation form
   const [invName, setInvName] = useState('');
@@ -272,6 +273,12 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
   function selectRxDrug(d) {
     setRxDrug(d.brand);
     setRxDrugTypeId(d.drug_type_id || null);
+    // Tablets/capsules/syrups/injections aren't applied to an eye --
+    // skip the Eye field entirely for those instead of forcing a
+    // meaningless RE/LE/BE choice. Unknown/free-text drugs default to
+    // showing it (can't tell, and most of this hospital's prescribing
+    // is ocular anyway).
+    setRxIsOcular(d.master_drug_types?.is_ocular !== false);
     setRxDosage('');
     setShowRxSuggestions(false);
   }
@@ -289,9 +296,9 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
     setError('');
     if (!rxDrug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
     if (!rxDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
-    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, dosage: rxDosage, eye: rxEye, steps: taperSteps });
+    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, dosage: rxDosage, eye: rxIsOcular ? rxEye : null, steps: taperSteps });
     if (result.error) { setError(result.error); return; }
-    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setShowTaperBuilder(false);
+    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setRxIsOcular(true); setShowTaperBuilder(false);
     refresh();
   }
 
@@ -299,7 +306,7 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
     setError('');
     if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
     const result = await addPrescription(data.encounter.id, {
-      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
+      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxIsOcular ? rxEye : null,
     });
     if (result.error) { setError(result.error); return; }
     setRxDrug('');
@@ -777,7 +784,7 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
                   return items.map((item) => item.type === 'single' ? (
                     <div key={item.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                       <span>
-                        <strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye}
+                        <strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration}{item.row.eye ? ` -- ${item.row.eye}` : ''}
                       </span>
                       <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(item.row.id, data.encounter.id); refresh(); }}>Remove</button>
                     </div>
@@ -785,7 +792,7 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
                     <div key={item.key} style={{ padding: '8px 10px', margin: '6px 0', background: 'var(--purple-lt)', borderRadius: 8, borderBottom: '1px solid var(--g100)' }}>
                       <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                         <span style={{ fontSize: 13 }}>
-                          <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye}
+                          <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage}{item.steps[0].eye ? ` -- ${item.steps[0].eye}` : ''}
                           <span style={{ marginLeft: 8, fontSize: 10.5, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering Schedule</span>
                         </span>
                         <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeTaperGroup(item.key, data.encounter.id); refresh(); }}>Remove Schedule</button>
@@ -812,7 +819,7 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
                       className="fi"
                       placeholder="Type to search medicines, or enter a new name"
                       value={rxDrug}
-                      onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setShowRxSuggestions(true); }}
+                      onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setRxIsOcular(true); setShowRxSuggestions(true); }}
                       onFocus={() => setShowRxSuggestions(true)}
                       onBlur={() => setTimeout(() => setShowRxSuggestions(false), 150)}
                       style={{ width: '100%' }}
@@ -863,11 +870,14 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
                   <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                     <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                   </select>
-                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 110 }}>
+                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 110, visibility: rxIsOcular ? 'visible' : 'hidden' }} disabled={!rxIsOcular}>
                     <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                   </select>
                   <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                 </div>
+                {!rxIsOcular && (
+                  <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 3 }}><i className="ti ti-info-circle"></i> {rxDrug} is not applied to the eye -- no Eye field needed.</div>
+                )}
 
                 {!showTaperBuilder ? (
                   <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }} onClick={() => setShowTaperBuilder(true)}>
@@ -876,7 +886,7 @@ export default function ConsultationForm({ queueEntryId, hideHistoryTracker = fa
                 ) : (
                   <div style={{ marginTop: 10, padding: 12, background: 'var(--purple-lt)', borderRadius: 8 }}>
                     <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--purple)', marginBottom: 8 }}>
-                      <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug, Dosage &amp; Eye entered above; frequency reduces step by step below
+                      <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug &amp; Dosage{rxIsOcular ? ' & Eye' : ''} entered above; frequency reduces step by step below
                     </div>
                     {taperSteps.map((s, i) => (
                       <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6 }}>
PATCH_EOF

git apply --check /tmp/eye_field_ocular_gating.patch
git apply /tmp/eye_field_ocular_gating.patch
rm /tmp/eye_field_ocular_gating.patch

echo "==> Patch applied cleanly. Running next build to verify..."
npm run build

echo "==> Build succeeded. Changes:"
echo "  - DB migration already applied directly via Supabase MCP to BOTH projects -- master_drug_types got an is_ocular boolean column (default true), set to false for Tablet/Capsule/Syrup/Injection, left true for Eye Drop/Eye Ointment/Gel. Nothing to run manually for this."
echo "  - Master Data > Financial Masters > Drug Types panel: new 'Eye medication' checkbox per type -- controls this going forward, including any new types you add later"
echo "  - Doctor module (Consultation prescription): picking a non-ocular drug (tablet/capsule/syrup/injection) now hides the Eye field automatically instead of forcing a meaningless RE/LE/BE choice. Free-typed drugs default to showing it since the type is unknown."
echo "  - Recovery & Discharge module: same logic applied to its medication entry (built last round) -- Eye field disappears for non-ocular drugs there too"
echo "  - Tapering builder helper text and the saved medicine list in both modules adjust automatically -- no more forced/blank Eye shown for tablets"
echo ""
echo "==> Committing and pushing..."
git add -A
git commit -m "Add is_ocular flag to drug types; hide Eye field for non-ocular medicines (tablets/capsules/syrups/injections) in Doctor and Discharge prescription forms"
git push origin main

echo "==> Done. Pushed to main -- Vercel will auto-deploy."
