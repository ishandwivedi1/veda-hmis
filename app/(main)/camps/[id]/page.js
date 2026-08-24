'use client';

import { useState, useEffect, useCallback, Suspense } from 'react';
import { useRouter, useParams, useSearchParams } from 'next/navigation';
import {
  getCampEvent, listScreenings, registerAttendee, deleteScreening,
  recordEyeCheckup, recordDoctorExamination,
  checkExistingPatientByPhone, linkScreeningToPatient, convertScreeningToPatient,
  sendCampScreeningWhatsApp, bulkSendCampScreeningWhatsApp,
} from '../actions';

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}
function fmtTime(t) {
  if (!t) return '';
  return new Date(t).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
}

// Same normalization as the real Patients registration form -- applied
// on blur so what the receptionist sees already matches what gets
// saved, instead of only fixing it after the fact server-side.
function toTitleCase(str) {
  if (!str) return str;
  return str
    .trim()
    .toLowerCase()
    .replace(/(^|[\s-'])\S/g, (c) => c.toUpperCase());
}

function StationTab({ active, onClick, icon, label, count, color }) {
  return (
    <button
      onClick={onClick}
      style={{
        flex: 1, padding: '10px 8px', borderRadius: 8, border: 'none', cursor: 'pointer',
        background: active ? color : 'var(--g100)', color: active ? '#fff' : 'var(--g600)',
        fontSize: 12.5, fontWeight: 600, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3,
      }}
    >
      <i className={`ti ${icon}`} style={{ fontSize: 18 }}></i>
      {label}
      <span style={{ fontSize: 10.5, opacity: 0.85 }}>{count}</span>
    </button>
  );
}

// ── STATION 1: REGISTRATION -- reception's own room. Fast add form up
// top, always visible; today's registrations listed below so they can
// see who's already in without leaving this screen. ──
function RegistrationStation({ campEventId, screenings, onRefresh }) {
  const [fullName, setFullName] = useState('');
  const [phone, setPhone] = useState('');
  const [age, setAge] = useState('');
  const [gender, setGender] = useState('M');
  const [whatsappConsent, setWhatsappConsent] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  async function handleAdd() {
    setError('');
    if (!fullName.trim() || !phone.trim()) { setError('Name and phone are required.'); return; }
    setSaving(true);
    const result = await registerAttendee(campEventId, { fullName, phone, age, gender, whatsappConsent });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setFullName(''); setPhone(''); setAge(''); setGender('M'); setWhatsappConsent(true);
    onRefresh();
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-user-plus" style={{ color: 'var(--blue)' }}></i> Register Attendee</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 0.6fr 0.7fr', gap: 8, marginBottom: 10 }}>
          <input className="fi" placeholder="Full name*" value={fullName} onChange={(e) => setFullName(e.target.value)} onBlur={() => setFullName((v) => toTitleCase(v))} autoFocus />
          <input className="fi" placeholder="Phone*" value={phone} onChange={(e) => setPhone(e.target.value)} />
          <input className="fi" placeholder="Age" value={age} onChange={(e) => setAge(e.target.value)} />
          <select className="fi" value={gender} onChange={(e) => setGender(e.target.value)}>
            <option value="M">Male</option><option value="F">Female</option><option value="O">Other</option>
          </select>
        </div>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12.5, cursor: 'pointer', marginBottom: 10 }}>
          <input type="checkbox" checked={whatsappConsent} onChange={(e) => setWhatsappConsent(e.target.checked)} />
          OK to message on WhatsApp about their results
        </label>
        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}
        <button className="btn btn-primary" onClick={handleAdd} disabled={saving}>
          <i className="ti ti-check"></i> {saving ? 'Adding...' : 'Add & Next'}
        </button>
      </div>

      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g600)', marginBottom: 8 }}>Registered so far ({screenings.length})</div>
      <table className="tbl">
        <thead><tr><th>Name</th><th>Phone</th><th>Age/Gender</th><th>Time</th></tr></thead>
        <tbody>
          {[...screenings].reverse().map((s) => (
            <tr key={s.id}>
              <td>{s.full_name}</td>
              <td style={{ fontSize: 12 }}>{s.phone}</td>
              <td style={{ fontSize: 12 }}>{s.age || '--'}{s.gender ? `/${s.gender}` : ''}</td>
              <td style={{ fontSize: 11, color: 'var(--g400)' }}>{fmtTime(s.created_at)}</td>
            </tr>
          ))}
          {screenings.length === 0 && <tr><td colSpan={4} style={{ textAlign: 'center', padding: 20, color: 'var(--g400)' }}>No one registered yet.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}

// ── STATION 2: EYE CHECKUP -- optometrist's room. A queue of people
// who've registered but haven't had VA recorded yet; pick one, enter
// VA, Save & Next automatically clears back to the queue. ──
function EyeCheckupStation({ pending, done, onRefresh }) {
  const [selected, setSelected] = useState(null);
  const [vaOd, setVaOd] = useState('');
  const [vaOs, setVaOs] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  function pick(s) {
    setSelected(s);
    setVaOd(''); setVaOs('');
    setError('');
  }

  async function handleSave() {
    if (!vaOd.trim() && !vaOs.trim()) { setError('Enter at least one eye\u2019s VA.'); return; }
    setSaving(true);
    const result = await recordEyeCheckup(selected.id, { vaOd, vaOs });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSelected(null);
    onRefresh();
  }

  if (selected) {
    return (
      <div className="card" style={{ maxWidth: 420 }}>
        <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={() => setSelected(null)}><i className="ti ti-arrow-left"></i> Back to queue</button>
        <div className="card-title" style={{ marginBottom: 2 }}>{selected.full_name}</div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 14 }}>{selected.phone} -- {selected.age || '--'}{selected.gender ? `/${selected.gender}` : ''}</div>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 14 }}>
          <div><label className="flbl">VA -- Right eye (OD)</label><input className="fi" value={vaOd} onChange={(e) => setVaOd(e.target.value)} placeholder="e.g. 6/9" autoFocus /></div>
          <div><label className="flbl">VA -- Left eye (OS)</label><input className="fi" value={vaOs} onChange={(e) => setVaOs(e.target.value)} placeholder="e.g. 6/12" /></div>
        </div>
        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}
        <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
          <i className="ti ti-check"></i> {saving ? 'Saving...' : 'Save & Next'}
        </button>
      </div>
    );
  }

  return (
    <div>
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g600)', marginBottom: 8 }}>Waiting for eye checkup ({pending.length})</div>
      {pending.length === 0 ? (
        <div className="card" style={{ textAlign: 'center', padding: 24, color: 'var(--g400)' }}>Queue is empty -- everyone registered has been checked.</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 20 }}>
          {pending.map((s) => (
            <div key={s.id} onClick={() => pick(s)} className="card" style={{ padding: '10px 14px', cursor: 'pointer', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div><strong>{s.full_name}</strong> <span style={{ fontSize: 11.5, color: 'var(--g400)' }}>{s.phone} -- {s.age || '--'}{s.gender ? `/${s.gender}` : ''}</span></div>
              <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
            </div>
          ))}
        </div>
      )}
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g600)', marginBottom: 8 }}>Already checked ({done.length})</div>
      <table className="tbl">
        <thead><tr><th>Name</th><th>VA (OD/OS)</th><th>By</th></tr></thead>
        <tbody>
          {done.map((s) => (
            <tr key={s.id}><td>{s.full_name}</td><td style={{ fontSize: 12 }}>{s.va_od || '--'} / {s.va_os || '--'}</td><td style={{ fontSize: 11, color: 'var(--g400)' }}>{s.eye_checkup_profile?.full_name || '--'}</td></tr>
          ))}
          {done.length === 0 && <tr><td colSpan={3} style={{ textAlign: 'center', padding: 16, color: 'var(--g400)' }}>None yet.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}

// ── STATION 3: DOCTOR EXAM -- doctor's room. Same queue pattern, but
// only pulls from people who've cleared the eye checkup, and shows VA
// results for context before the doctor records a finding. ──
function DoctorExamStation({ pending, done, onRefresh }) {
  const [selected, setSelected] = useState(null);
  const [finding, setFinding] = useState('');
  const [referralRecommended, setReferralRecommended] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  function pick(s) {
    setSelected(s);
    setFinding(''); setReferralRecommended(false);
    setError('');
  }

  async function handleSave() {
    setSaving(true);
    const result = await recordDoctorExamination(selected.id, { finding, referralRecommended });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSelected(null);
    onRefresh();
  }

  if (selected) {
    return (
      <div className="card" style={{ maxWidth: 460 }}>
        <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={() => setSelected(null)}><i className="ti ti-arrow-left"></i> Back to queue</button>
        <div className="card-title" style={{ marginBottom: 2 }}>{selected.full_name}</div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 4 }}>{selected.phone} -- {selected.age || '--'}{selected.gender ? `/${selected.gender}` : ''}</div>
        <div style={{ fontSize: 12.5, background: 'var(--g50)', borderRadius: 8, padding: '6px 10px', marginBottom: 14, display: 'inline-block' }}>
          VA: OD {selected.va_od || '--'} / OS {selected.va_os || '--'}
        </div>

        <label className="flbl">Finding</label>
        <textarea className="fi" rows={2} style={{ marginBottom: 10 }} value={finding} onChange={(e) => setFinding(e.target.value)} placeholder="e.g. possible cataract, high refractive error, normal..." autoFocus />
        <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12.5, cursor: 'pointer', marginBottom: 14 }}>
          <input type="checkbox" checked={referralRecommended} onChange={(e) => setReferralRecommended(e.target.checked)} />
          Recommend a hospital visit for detailed checkup
        </label>
        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}
        <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
          <i className="ti ti-check"></i> {saving ? 'Saving...' : 'Save & Next'}
        </button>
      </div>
    );
  }

  return (
    <div>
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g600)', marginBottom: 8 }}>Waiting for doctor examination ({pending.length})</div>
      {pending.length === 0 ? (
        <div className="card" style={{ textAlign: 'center', padding: 24, color: 'var(--g400)' }}>Queue is empty -- nobody's waiting on you right now.</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6, marginBottom: 20 }}>
          {pending.map((s) => (
            <div key={s.id} onClick={() => pick(s)} className="card" style={{ padding: '10px 14px', cursor: 'pointer', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div><strong>{s.full_name}</strong> <span style={{ fontSize: 11.5, color: 'var(--g400)' }}>{s.phone} -- VA {s.va_od || '--'}/{s.va_os || '--'}</span></div>
              <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
            </div>
          ))}
        </div>
      )}
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g600)', marginBottom: 8 }}>Already examined ({done.length})</div>
      <table className="tbl">
        <thead><tr><th>Name</th><th>Finding</th><th>By</th></tr></thead>
        <tbody>
          {done.map((s) => (
            <tr key={s.id}>
              <td>{s.full_name}</td>
              <td style={{ fontSize: 12 }}>{s.finding || <span style={{ color: 'var(--g400)' }}>No issues noted</span>}{s.referral_recommended && <span className="badge b-amber" style={{ marginLeft: 6, fontSize: 10 }}>Referral</span>}</td>
              <td style={{ fontSize: 11, color: 'var(--g400)' }}>{s.doctor_review_profile?.full_name || '--'}</td>
            </tr>
          ))}
          {done.length === 0 && <tr><td colSpan={3} style={{ textAlign: 'center', padding: 16, color: 'var(--g400)' }}>None yet.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}

function ConvertModal({ screening, onClose, onConverted }) {
  const nameParts = (screening.full_name || '').trim().split(/\s+/);
  const [firstName, setFirstName] = useState(nameParts[0] || '');
  const [lastName, setLastName] = useState(nameParts.slice(1).join(' ') || '');
  const [age, setAge] = useState(screening.age || '');
  const [gender, setGender] = useState(screening.gender || 'M');
  const [mobile, setMobile] = useState(screening.phone || '');
  const [address, setAddress] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  async function handleConvert() {
    setError('');
    if (!firstName.trim() || !mobile.trim()) { setError('First name and mobile are required.'); return; }
    setSaving(true);
    const result = await convertScreeningToPatient(screening.id, {
      firstName, lastName, age, gender, mobile, address,
      referralSource: 'Corporate/Community Camp',
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onConverted(result.patient);
  }

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }}>
      <div className="card" style={{ width: 460, maxWidth: '90vw' }}>
        <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-user-plus" style={{ color: 'var(--green)' }}></i> Convert to Patient</div>
        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 14 }}>Pre-filled from the camp entry -- check and complete before registering.</div>

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">First name<sup style={{ color: 'var(--red)' }}>*</sup></label><input className="fi" value={firstName} onChange={(e) => setFirstName(e.target.value)} onBlur={() => setFirstName((v) => toTitleCase(v))} /></div>
          <div><label className="flbl">Last name</label><input className="fi" value={lastName} onChange={(e) => setLastName(e.target.value)} onBlur={() => setLastName((v) => toTitleCase(v))} /></div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">Age</label><input className="fi" value={age} onChange={(e) => setAge(e.target.value)} /></div>
          <div>
            <label className="flbl">Gender</label>
            <select className="fi" value={gender} onChange={(e) => setGender(e.target.value)}>
              <option value="M">Male</option><option value="F">Female</option><option value="O">Other</option>
            </select>
          </div>
          <div><label className="flbl">Mobile<sup style={{ color: 'var(--red)' }}>*</sup></label><input className="fi" value={mobile} onChange={(e) => setMobile(e.target.value)} /></div>
        </div>
        <label className="flbl">Address</label>
        <input className="fi" style={{ marginBottom: 14 }} value={address} onChange={(e) => setAddress(e.target.value)} placeholder="Optional" />

        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button className="btn" onClick={onClose} disabled={saving}>Cancel</button>
          <button className="btn btn-primary" onClick={handleConvert} disabled={saving}>
            <i className="ti ti-check"></i> {saving ? 'Registering...' : 'Register Patient'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── OVERVIEW -- the organizer's view: everyone, every stage, at a
// glance. Convert to Patient and WhatsApp send both live here, not in
// the individual stations, since they're camp-organizer actions, not
// part of any one room's job. ──
function OverviewStation({ screenings, onDelete, onConvert, onSendWhatsApp, sendingId }) {
  const [dupeChecks, setDupeChecks] = useState({});

  async function checkDupes(s) {
    const found = await checkExistingPatientByPhone(s.phone);
    setDupeChecks((prev) => ({ ...prev, [s.id]: found }));
  }

  function stageLabel(s) {
    if (s.doctor_reviewed_at) return <span className="badge b-green">Doctor Reviewed</span>;
    if (s.eye_checkup_done_at) return <span className="badge b-blue">Eye Checkup Done</span>;
    return <span className="badge b-gray">Registered</span>;
  }

  return (
    <table className="tbl">
      <thead><tr><th>Attendee</th><th>Stage</th><th>VA (OD/OS)</th><th>Finding</th><th>Patient</th><th>WhatsApp</th><th></th></tr></thead>
      <tbody>
        {screenings.map((s) => (
          <tr key={s.id}>
            <td>
              <strong>{s.full_name}</strong>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{s.phone} -- {s.age || '--'}{s.gender ? `/${s.gender}` : ''}</div>
            </td>
            <td>{stageLabel(s)}</td>
            <td style={{ fontSize: 12 }}>{s.va_od || '--'} / {s.va_os || '--'}</td>
            <td style={{ fontSize: 12, maxWidth: 200 }}>
              {s.finding || <span style={{ color: 'var(--g400)' }}>--</span>}
              {s.referral_recommended && <span className="badge b-amber" style={{ marginLeft: 6, fontSize: 10 }}>Referral</span>}
            </td>
            <td>
              {s.patient_id ? (
                <span className="badge b-green"><i className="ti ti-check"></i> {s.patients?.uhid}</span>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4, alignItems: 'flex-start' }}>
                  <button className="btn btn-sm" onClick={() => onConvert(s)}>Convert</button>
                  {!(s.id in dupeChecks) && <button className="btn btn-sm" style={{ fontSize: 10.5 }} onClick={() => checkDupes(s)}>Check existing?</button>}
                  {s.id in dupeChecks && dupeChecks[s.id].length > 0 && (
                    <div style={{ fontSize: 10.5, color: 'var(--amber)' }}>
                      Already a patient: {dupeChecks[s.id][0].uhid} -- <span style={{ textDecoration: 'underline', cursor: 'pointer' }} onClick={() => linkScreeningToPatient(s.id, dupeChecks[s.id][0].id).then(() => window.location.reload())}>Link</span>
                    </div>
                  )}
                  {s.id in dupeChecks && dupeChecks[s.id].length === 0 && <div style={{ fontSize: 10.5, color: 'var(--g400)' }}>No match found.</div>}
                </div>
              )}
            </td>
            <td>
              {s.whatsapp_sent_at ? (
                <span className="badge b-green" style={{ fontSize: 10 }}><i className="ti ti-check"></i> Sent</span>
              ) : !s.whatsapp_consent ? (
                <span style={{ fontSize: 10.5, color: 'var(--g400)' }}>No consent</span>
              ) : !s.doctor_reviewed_at ? (
                <span style={{ fontSize: 10.5, color: 'var(--g400)' }}>Awaiting exam</span>
              ) : (
                <button className="btn btn-sm" onClick={() => onSendWhatsApp(s.id)} disabled={sendingId === s.id}>
                  <i className="ti ti-brand-whatsapp"></i> {sendingId === s.id ? '...' : 'Send'}
                </button>
              )}
            </td>
            <td><button className="btn btn-sm" onClick={() => onDelete(s.id)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button></td>
          </tr>
        ))}
        {screenings.length === 0 && <tr><td colSpan={7} style={{ textAlign: 'center', padding: 24, color: 'var(--g400)' }}>No attendees logged yet.</td></tr>}
      </tbody>
    </table>
  );
}

function CampDetailInner() {
  const params = useParams();
  const router = useRouter();
  const searchParams = useSearchParams();
  const campEventId = params.id;
  const stationParam = searchParams.get('station');

  const [camp, setCamp] = useState(null);
  const [screenings, setScreenings] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [tab, setTab] = useState(['registration', 'checkup', 'doctor', 'overview'].includes(stationParam) ? stationParam : 'registration');
  const [convertTarget, setConvertTarget] = useState(null);
  const [sendingId, setSendingId] = useState(null);
  const [bulkSending, setBulkSending] = useState(false);
  const [bulkResult, setBulkResult] = useState('');

  const refresh = useCallback(async () => {
    const [campResult, screeningsResult] = await Promise.all([getCampEvent(campEventId), listScreenings(campEventId)]);
    if (campResult.error) { setError(campResult.error); setLoading(false); return; }
    setCamp(campResult.camp);
    setScreenings(screeningsResult.rows || []);
    setLoading(false);
  }, [campEventId]);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleDelete(id) {
    await deleteScreening(id);
    refresh();
  }

  async function handleSendWhatsApp(id) {
    setSendingId(id);
    await sendCampScreeningWhatsApp(id);
    setSendingId(null);
    refresh();
  }

  async function handleBulkSend() {
    setBulkSending(true);
    setBulkResult('');
    const result = await bulkSendCampScreeningWhatsApp(campEventId);
    setBulkSending(false);
    if (result.error) { setBulkResult(`Error: ${result.error}`); return; }
    setBulkResult(`Sent ${result.sent}, failed ${result.failed}.`);
    refresh();
  }

  if (loading) return <div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>;
  if (error) return <div className="msg-err">{error}</div>;

  const pendingCheckup = screenings.filter((s) => !s.eye_checkup_done_at);
  const checkedUp = screenings.filter((s) => s.eye_checkup_done_at);
  const pendingDoctor = checkedUp.filter((s) => !s.doctor_reviewed_at);
  const doctorDone = checkedUp.filter((s) => s.doctor_reviewed_at);
  const convertedCount = screenings.filter((s) => s.patient_id).length;
  const consentedUnsent = screenings.filter((s) => s.whatsapp_consent && s.doctor_reviewed_at && !s.whatsapp_sent_at).length;

  return (
    <div>
      <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={() => router.push('/camps')}><i className="ti ti-arrow-left"></i> All Camps</button>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 16 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{camp.name}</div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>
            {fmtDate(camp.camp_date)}{camp.location ? ` -- ${camp.location}` : ''}{camp.conducted_by ? ` -- ${camp.conducted_by}` : ''}
          </div>
        </div>
        <div style={{ display: 'flex', gap: 16, textAlign: 'center' }}>
          <div><div style={{ fontSize: 20, fontWeight: 800 }}>{screenings.length}</div><div style={{ fontSize: 10.5, color: 'var(--g500)' }}>Registered</div></div>
          <div><div style={{ fontSize: 20, fontWeight: 800, color: 'var(--green)' }}>{convertedCount}</div><div style={{ fontSize: 10.5, color: 'var(--g500)' }}>Converted</div></div>
        </div>
      </div>

      {/* Each of the 3 stations is meant to be its own device/tab, deep-linkable
          via ?station=registration|checkup|doctor|overview so reception,
          optometry, and the doctor's room can each bookmark straight to
          their own queue instead of clicking through every time. */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 18 }}>
        <StationTab active={tab === 'registration'} onClick={() => setTab('registration')} icon="ti-user-plus" label="Registration" count={screenings.length} color="var(--blue)" />
        <StationTab active={tab === 'checkup'} onClick={() => setTab('checkup')} icon="ti-eye" label="Eye Checkup" count={pendingCheckup.length} color="var(--teal)" />
        <StationTab active={tab === 'doctor'} onClick={() => setTab('doctor')} icon="ti-stethoscope" label="Doctor Exam" count={pendingDoctor.length} color="var(--indigo)" />
        <StationTab active={tab === 'overview'} onClick={() => setTab('overview')} icon="ti-layout-dashboard" label="Overview" count={screenings.length} color="var(--g600)" />
      </div>

      {tab === 'overview' && consentedUnsent > 0 && (
        <div style={{ marginBottom: 16 }}>
          <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleBulkSend} disabled={bulkSending}>
            <i className="ti ti-brand-whatsapp"></i> {bulkSending ? 'Sending...' : `Send WhatsApp to ${consentedUnsent} pending`}
          </button>
          {bulkResult && <span style={{ fontSize: 11.5, color: 'var(--g500)', marginLeft: 10 }}>{bulkResult}</span>}
        </div>
      )}

      {tab === 'registration' && <RegistrationStation campEventId={campEventId} screenings={screenings} onRefresh={refresh} />}
      {tab === 'checkup' && <EyeCheckupStation pending={pendingCheckup} done={checkedUp} onRefresh={refresh} />}
      {tab === 'doctor' && <DoctorExamStation pending={pendingDoctor} done={doctorDone} onRefresh={refresh} />}
      {tab === 'overview' && (
        <OverviewStation
          screenings={screenings}
          onDelete={handleDelete}
          onConvert={setConvertTarget}
          onSendWhatsApp={handleSendWhatsApp}
          sendingId={sendingId}
        />
      )}

      {convertTarget && (
        <ConvertModal
          screening={convertTarget}
          onClose={() => setConvertTarget(null)}
          onConverted={() => { setConvertTarget(null); refresh(); }}
        />
      )}
    </div>
  );
}

export default function CampDetailPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <CampDetailInner />
    </Suspense>
  );
}
