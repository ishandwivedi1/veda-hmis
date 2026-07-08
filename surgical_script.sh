mkdir -p 'app/(main)/surgical' 'app/(main)/ot-schedule' 'app/(main)/consultation/[id]' app/components

cat > 'app/(main)/surgical/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function markForSurgery(patientId, encounterId, procedureName, eye) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').insert({
    patient_id: patientId, encounter_id: encounterId, procedure_name: procedureName, eye,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getSurgicalCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients(first_name, last_name, uhid), master_packages(name, price)')
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

export async function getPackagesForSelection() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function selectPackage(caseId, packageId) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ package_id: packageId }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function updateChecklistItem(caseId, field, value) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ [field]: value }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markReadyForScheduling(caseId) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('*').eq('id', caseId).single();
  if (!sc.consent_taken || !sc.biometry_done || !sc.fitness_cleared) {
    return { error: 'All three checklist items must be complete before scheduling.' };
  }
  if (!sc.package_id) {
    return { error: 'Select a package first.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function getSurgeons() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name').ilike('designation', '%ophthalmologist%').eq('status', 'Active');
  return data || [];
}

export async function scheduleOT(caseId, surgeonId, date, time, notes) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').insert({
    surgical_case_id: caseId, surgeon_id: surgeonId || null, scheduled_date: date, scheduled_time: time || null, notes,
  });
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

export async function getOTSchedule() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles(full_name)')
    .neq('status', 'Cancelled')
    .order('scheduled_date', { ascending: true });
  if (error) return [];
  return data;
}

export async function completeOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

EOF

cat > 'app/(main)/surgical/page.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getSurgicalCases, getPackagesForSelection, selectPackage,
  updateChecklistItem, markReadyForScheduling,
} from './actions';

function CaseCard({ sc, packages, onUpdate }) {
  const [error, setError] = useState('');

  async function handlePackage(e) {
    await selectPackage(sc.id, e.target.value);
    onUpdate();
  }

  async function handleChecklist(field, checked) {
    await updateChecklistItem(sc.id, field, checked);
    onUpdate();
  }

  async function handleReady() {
    setError('');
    const result = await markReadyForScheduling(sc.id);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-head">
        <div>
          <div style={{ fontWeight: 700, fontSize: 14 }}>
            {sc.patients.first_name} {sc.patients.last_name} -- {sc.patients.uhid}
          </div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>{sc.procedure_name} -- {sc.eye}</div>
        </div>
        <span className={`badge ${sc.status === 'Ready for Scheduling' ? 'b-green' : 'b-amber'}`}>{sc.status}</span>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Package</label>
        <select className="fi" value={sc.package_id || ''} onChange={handlePackage}>
          <option value="">-- Select package --</option>
          {packages.map((p) => (
            <option key={p.id} value={p.id}>{p.name} -- Rs.{p.price}</option>
          ))}
        </select>
      </div>

      <div style={{ display: 'flex', gap: 20, marginBottom: 12 }}>
        <label style={{ fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={sc.consent_taken} onChange={(e) => handleChecklist('consent_taken', e.target.checked)} />
          Consent taken
        </label>
        <label style={{ fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={sc.biometry_done} onChange={(e) => handleChecklist('biometry_done', e.target.checked)} />
          Biometry done
        </label>
        <label style={{ fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={sc.fitness_cleared} onChange={(e) => handleChecklist('fitness_cleared', e.target.checked)} />
          Fitness cleared
        </label>
      </div>

      {sc.status === 'Pending Workup' && (
        <button className="btn btn-primary btn-sm" onClick={handleReady}>Mark Ready for Scheduling</button>
      )}
      {sc.status === 'Ready for Scheduling' && (
        <div className="msg-success" style={{ margin: 0 }}>
          <i className="ti ti-circle-check"></i> Ready -- go to OT Scheduling to book a date.
        </div>
      )}
    </div>
  );
}

export default function SurgicalPage() {
  const [cases, setCases] = useState([]);
  const [packages, setPackages] = useState([]);

  const refresh = useCallback(async () => {
    setCases(await getSurgicalCases());
    setPackages(await getPackagesForSelection());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div>
      {cases.map((sc) => (
        <CaseCard key={sc.id} sc={sc} packages={packages} onUpdate={refresh} />
      ))}
      {cases.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No surgical cases pending workup. Mark a patient for surgery from their Consultation.
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/(main)/ot-schedule/page.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getSurgicalCases, getSurgeons, scheduleOT, getOTSchedule, completeOT } from './actions';

function ScheduleForm({ sc, surgeons, onScheduled }) {
  const [surgeonId, setSurgeonId] = useState('');
  const [date, setDate] = useState('');
  const [time, setTime] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSchedule() {
    setError('');
    if (!date) { setError('Date is required.'); return; }
    setLoading(true);
    const result = await scheduleOT(sc.id, surgeonId, date, time, notes);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    onScheduled();
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 4 }}>
        {sc.patients.first_name} {sc.patients.last_name} -- {sc.patients.uhid}
      </div>
      <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12 }}>{sc.procedure_name} -- {sc.eye}</div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
        <select className="fi" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
          <option value="">-- Surgeon --</option>
          {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
        </select>
        <input type="date" className="fi" value={date} onChange={(e) => setDate(e.target.value)} />
        <input type="time" className="fi" value={time} onChange={(e) => setTime(e.target.value)} />
      </div>
      <input className="fi" placeholder="Notes" value={notes} onChange={(e) => setNotes(e.target.value)} style={{ marginBottom: 8 }} />
      <button className="btn btn-primary btn-sm" onClick={handleSchedule} disabled={loading}>
        {loading ? 'Scheduling...' : 'Schedule Surgery'}
      </button>
    </div>
  );
}

export default function OTSchedulePage() {
  const [readyCases, setReadyCases] = useState([]);
  const [surgeons, setSurgeons] = useState([]);
  const [schedule, setSchedule] = useState([]);

  const refresh = useCallback(async () => {
    const all = await getSurgicalCases();
    setReadyCases(all.filter((c) => c.status === 'Ready for Scheduling'));
    setSurgeons(await getSurgeons());
    setSchedule(await getOTSchedule());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId) {
    await completeOT(otId, caseId);
    refresh();
  }

  return (
    <div>
      {readyCases.length > 0 && (
        <>
          <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Ready to Schedule</div>
          {readyCases.map((sc) => (
            <ScheduleForm key={sc.id} sc={sc} surgeons={surgeons} onScheduled={refresh} />
          ))}
        </>
      )}

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> OT Schedule
        </div>
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Time</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {schedule.map((s) => (
              <tr key={s.id}>
                <td>{new Date(s.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</td>
                <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                <td>{s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}</td>
                <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                <td>{s.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${s.status === 'Completed' ? 'b-green' : 'b-blue'}`}>{s.status}</span></td>
                <td>
                  {s.status === 'Scheduled' && (
                    <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id)}>Complete</button>
                  )}
                </td>
              </tr>
            ))}
            {schedule.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/consultation/[id]/consultation-form.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
} from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/surgical/actions';

export default function ConsultationForm({ queueEntryId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [invPriority, setInvPriority] = useState('Routine');

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure.trim()) { setError('Procedure name is required.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
  }

  async function handleSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId)
      : await sendForInvestigationFromConsultation(queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const f = data.findings;

  return (
    <div style={{ maxWidth: 700, margin: '0 auto' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Consultation -- {data.entry.token}</div>
        <div style={{ fontSize: 13, color: 'var(--g500)' }}>
          {patient.first_name} {patient.last_name} -- {patient.uhid} -- {patient.age} {patient.gender}
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {f && (
        <div className="card" style={{ marginBottom: 16, background: 'var(--g50)' }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>Optometry Findings</div>
          <div style={{ fontSize: 12, color: 'var(--g600)' }}>
            VA: RE {f.re_va || '--'} / LE {f.le_va || '--'} &nbsp;&nbsp;
            IOP: RE {f.re_iop || '--'} / LE {f.le_iop || '--'} &nbsp;&nbsp;
            Sph: RE {f.re_sph || '--'} / LE {f.le_sph || '--'} &nbsp;&nbsp;
            Cyl: RE {f.re_cyl || '--'} / LE {f.le_cyl || '--'}
          </div>
        </div>
      )}

      {/* DIAGNOSIS */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Diagnosis</div>
        {data.diagnoses.map((d) => (
          <div key={d.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeDiagnosis(d.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
          <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
          <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
            <option value="primary">Primary</option>
            <option value="secondary">Secondary</option>
            <option value="associated">Associated</option>
            <option value="systemic">Systemic</option>
          </select>
          <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
            <option value="OD">OD</option>
            <option value="OS">OS</option>
            <option value="OU">OU</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
        </div>
      </div>

      {/* PRESCRIPTION */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Prescription</div>
        {data.prescriptions.map((r) => (
          <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap' }}>
          <input className="fi" placeholder="Drug name" value={rxDrug} onChange={(e) => setRxDrug(e.target.value)} style={{ flex: '2 1 160px' }} />
          <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
            <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
          </select>
          <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
            <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
          </select>
          <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
            <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
          </select>
          <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 70 }}>
            <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
        </div>
      </div>

      {/* INVESTIGATIONS */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Investigations</div>
        {data.investigations.map((i) => (
          <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
          <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
          <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 70 }}>
            <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
          </select>
          <select className="fi" value={invPriority} onChange={(e) => setInvPriority(e.target.value)} style={{ flex: 1 }}>
            <option>Routine</option><option>Urgent</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
        </div>
      </div>

      {/* SURGERY */}
      <div className="card" style={{ marginBottom: 16 }}>
        {!showSurgery ? (
          <button className="btn" onClick={() => setShowSurgery(true)}>
            <i className="ti ti-scalpel"></i> Mark for Surgery
          </button>
        ) : (
          <div>
            <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Mark for Surgery</div>
            <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
              <input className="fi" placeholder="Procedure (e.g. Phacoemulsification + IOL)" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }} />
              <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 80 }}>
                <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
              </select>
            </div>
            <div style={{ display: 'flex', gap: 6 }}>
              <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                {surgeryLoading ? 'Saving...' : 'Save'}
              </button>
              <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
            </div>
          </div>
        )}
      </div>

      {/* ACTIONS */}
      <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
          {loading ? 'Working...' : 'Complete Visit'}
        </button>
        <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
          Send for Dilation
        </button>
        <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
          Send for Investigation
        </button>
      </div>
    </div>
  );
}

EOF

cat > 'app/components/AppShell.js' << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Open Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/surgical', label: 'Surgical Coordination', icon: 'ti-scalpel', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Scheduling', icon: 'ti-calendar-time', section: 'Surgical' },
  { href: '/master-data', label: 'Master Data', icon: 'ti-database', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Open Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/optometry/, title: 'Optometry' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/surgical/, title: 'Surgical Coordination' },
  { match: /^\/ot-schedule/, title: 'OT Scheduling' },
  { match: /^\/master-data/, title: 'Master Data' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${pathname.startsWith(item.href) ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                {item.label}
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}

EOF

echo "Surgical Coordination + OT Scheduling module created."
