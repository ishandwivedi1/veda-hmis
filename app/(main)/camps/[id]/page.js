'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter, useParams } from 'next/navigation';
import {
  getCampEvent, listScreenings, addScreening, deleteScreening,
  checkExistingPatientByPhone, linkScreeningToPatient, convertScreeningToPatient,
  sendCampScreeningWhatsApp, bulkSendCampScreeningWhatsApp,
} from '../actions';

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function blankEntry() {
  return { fullName: '', phone: '', age: '', gender: 'M', vaOd: '', vaOs: '', finding: '', referralRecommended: false, whatsappConsent: true };
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
          <div><label className="flbl">First name<sup style={{ color: 'var(--red)' }}>*</sup></label><input className="fi" value={firstName} onChange={(e) => setFirstName(e.target.value)} /></div>
          <div><label className="flbl">Last name</label><input className="fi" value={lastName} onChange={(e) => setLastName(e.target.value)} /></div>
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

function ScreeningRow({ s, onDelete, onConvert, onSendWhatsApp, sending }) {
  const [dupes, setDupes] = useState(null);
  const [checkedDupes, setCheckedDupes] = useState(false);

  async function checkDupes() {
    const found = await checkExistingPatientByPhone(s.phone);
    setDupes(found);
    setCheckedDupes(true);
  }

  return (
    <tr>
      <td>
        <strong>{s.full_name}</strong>
        <div style={{ fontSize: 11, color: 'var(--g400)' }}>{s.phone} -- {s.age || '--'}{s.gender ? `/${s.gender}` : ''}</div>
      </td>
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
            <button className="btn btn-sm" onClick={onConvert}>Convert</button>
            {!checkedDupes && <button className="btn btn-sm" style={{ fontSize: 10.5 }} onClick={checkDupes}>Check existing?</button>}
            {checkedDupes && dupes?.length > 0 && (
              <div style={{ fontSize: 10.5, color: 'var(--amber)' }}>
                Already a patient: {dupes[0].uhid} -- <span style={{ textDecoration: 'underline', cursor: 'pointer' }} onClick={() => linkScreeningToPatient(s.id, dupes[0].id).then(() => window.location.reload())}>Link</span>
              </div>
            )}
            {checkedDupes && dupes?.length === 0 && <div style={{ fontSize: 10.5, color: 'var(--g400)' }}>No match found.</div>}
          </div>
        )}
      </td>
      <td>
        {s.whatsapp_sent_at ? (
          <span className="badge b-green" style={{ fontSize: 10 }}><i className="ti ti-check"></i> Sent</span>
        ) : s.whatsapp_consent ? (
          <button className="btn btn-sm" onClick={onSendWhatsApp} disabled={sending}>
            <i className="ti ti-brand-whatsapp"></i> {sending ? '...' : 'Send'}
          </button>
        ) : (
          <span style={{ fontSize: 10.5, color: 'var(--g400)' }}>No consent</span>
        )}
      </td>
      <td><button className="btn btn-sm" onClick={onDelete}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button></td>
    </tr>
  );
}

export default function CampDetailPage() {
  const params = useParams();
  const router = useRouter();
  const campEventId = params.id;

  const [camp, setCamp] = useState(null);
  const [screenings, setScreenings] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
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

  async function handleAddScreening(values) {
    const result = await addScreening(campEventId, values);
    if (!result.error) refresh();
    return result;
  }

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

  const convertedCount = screenings.filter((s) => s.patient_id).length;
  const consentedUnsent = screenings.filter((s) => s.whatsapp_consent && !s.whatsapp_sent_at).length;

  return (
    <div>
      <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={() => router.push('/camps')}><i className="ti ti-arrow-left"></i> All Camps</button>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 4 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{camp.name}</div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>
            {fmtDate(camp.camp_date)}{camp.location ? ` -- ${camp.location}` : ''}{camp.conducted_by ? ` -- ${camp.conducted_by}` : ''}
          </div>
        </div>
        <div style={{ display: 'flex', gap: 16, textAlign: 'center' }}>
          <div><div style={{ fontSize: 20, fontWeight: 800 }}>{screenings.length}</div><div style={{ fontSize: 10.5, color: 'var(--g500)' }}>Screened</div></div>
          <div><div style={{ fontSize: 20, fontWeight: 800, color: 'var(--green)' }}>{convertedCount}</div><div style={{ fontSize: 10.5, color: 'var(--g500)' }}>Converted</div></div>
        </div>
      </div>

      {consentedUnsent > 0 && (
        <div style={{ margin: '12px 0' }}>
          <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleBulkSend} disabled={bulkSending}>
            <i className="ti ti-brand-whatsapp"></i> {bulkSending ? 'Sending...' : `Send WhatsApp to ${consentedUnsent} pending`}
          </button>
          {bulkResult && <span style={{ fontSize: 11.5, color: 'var(--g500)', marginLeft: 10 }}>{bulkResult}</span>}
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        <QuickAddFormWrapper campEventId={campEventId} onAdd={handleAddScreening} />
      </div>

      {screenings.length === 0 ? (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No attendees logged yet.</div>
      ) : (
        <table className="tbl">
          <thead><tr><th>Attendee</th><th>VA (OD/OS)</th><th>Finding</th><th>Patient</th><th>WhatsApp</th><th></th></tr></thead>
          <tbody>
            {screenings.map((s) => (
              <ScreeningRow
                key={s.id} s={s}
                onDelete={() => handleDelete(s.id)}
                onConvert={() => setConvertTarget(s)}
                onSendWhatsApp={() => handleSendWhatsApp(s.id)}
                sending={sendingId === s.id}
              />
            ))}
          </tbody>
        </table>
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

// Wraps QuickAddForm so it knows which camp it's adding into --
// avoids threading campEventId through the shared form component's
// own state shape.
function QuickAddFormWrapper({ campEventId, onAdd }) {
  const [entry, setEntry] = useState(blankEntry());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  async function handleAdd() {
    setError('');
    if (!entry.fullName.trim() || !entry.phone.trim()) { setError('Name and phone are required.'); return; }
    setSaving(true);
    const result = await onAdd(entry);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setEntry(blankEntry());
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-plus" style={{ color: 'var(--blue)' }}></i> Add Attendee</div>
      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 0.6fr 0.7fr', gap: 8, marginBottom: 8 }}>
        <input className="fi fi-sm" placeholder="Full name*" value={entry.fullName} onChange={(e) => setEntry({ ...entry, fullName: e.target.value })} />
        <input className="fi fi-sm" placeholder="Phone*" value={entry.phone} onChange={(e) => setEntry({ ...entry, phone: e.target.value })} />
        <input className="fi fi-sm" placeholder="Age" value={entry.age} onChange={(e) => setEntry({ ...entry, age: e.target.value })} />
        <select className="fi fi-sm" value={entry.gender} onChange={(e) => setEntry({ ...entry, gender: e.target.value })}>
          <option value="M">Male</option><option value="F">Female</option><option value="O">Other</option>
        </select>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '0.5fr 0.5fr 1.5fr', gap: 8, marginBottom: 8 }}>
        <input className="fi fi-sm" placeholder="VA (OD)" value={entry.vaOd} onChange={(e) => setEntry({ ...entry, vaOd: e.target.value })} />
        <input className="fi fi-sm" placeholder="VA (OS)" value={entry.vaOs} onChange={(e) => setEntry({ ...entry, vaOs: e.target.value })} />
        <input className="fi fi-sm" placeholder="Finding / flag (e.g. possible cataract)" value={entry.finding} onChange={(e) => setEntry({ ...entry, finding: e.target.value })} />
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 10 }}>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, cursor: 'pointer' }}>
          <input type="checkbox" checked={entry.referralRecommended} onChange={(e) => setEntry({ ...entry, referralRecommended: e.target.checked })} />
          Recommend hospital visit
        </label>
        <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, cursor: 'pointer' }}>
          <input type="checkbox" checked={entry.whatsappConsent} onChange={(e) => setEntry({ ...entry, whatsappConsent: e.target.checked })} />
          OK to message on WhatsApp
        </label>
      </div>
      {error && <div className="msg-err" style={{ marginBottom: 8 }}>{error}</div>}
      <button className="btn btn-primary btn-sm" onClick={handleAdd} disabled={saving}>
        <i className="ti ti-check"></i> {saving ? 'Adding...' : 'Add & Next'}
      </button>
    </div>
  );
}
