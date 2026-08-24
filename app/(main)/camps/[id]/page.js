'use client';

import { useState, useEffect, useCallback, Suspense } from 'react';
import { useRouter, useParams, useSearchParams } from 'next/navigation';
import {
  getCampEvent, listScreenings, registerAttendee, updateRegistration, deleteScreening,
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
// see who's already in without leaving this screen. Clicking a row
// opens it for a quick correction (name misspelled, wrong number in a
// hurry, etc.) instead of that mistake sitting there uneditable. ──
function RegistrationStation({ campEventId, screenings, onRefresh }) {
  const [fullName, setFullName] = useState('');
  const [phone, setPhone] = useState('');
  const [age, setAge] = useState('');
  const [gender, setGender] = useState('M');
  const [whatsappConsent, setWhatsappConsent] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const [editingId, setEditingId] = useState(null);
  const [editValues, setEditValues] = useState(null);
  const [editSaving, setEditSaving] = useState(false);
  const [editError, setEditError] = useState('');

  async function handleAdd() {
    setError('');
    if (!fullName.trim() || !phone.trim()) { setError('Name and phone are required.'); return; }
    if (!/^\d{10}$/.test(phone.trim())) { setError('Mobile number must be 10 digits.'); return; }
    setSaving(true);
    const result = await registerAttendee(campEventId, { fullName, phone, age, gender, whatsappConsent });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setFullName(''); setPhone(''); setAge(''); setGender('M'); setWhatsappConsent(true);
    onRefresh();
  }

  function startEdit(s) {
    setEditingId(s.id);
    setEditValues({ fullName: s.full_name, phone: s.phone, age: s.age || '', gender: s.gender || 'M', whatsappConsent: s.whatsapp_consent });
    setEditError('');
  }

  async function saveEdit() {
    setEditError('');
    if (!editValues.fullName.trim() || !editValues.phone.trim()) { setEditError('Name and phone are required.'); return; }
    if (!/^\d{10}$/.test(editValues.phone.trim())) { setEditError('Mobile number must be 10 digits.'); return; }
    setEditSaving(true);
    const result = await updateRegistration(editingId, { ...editValues, fullName: toTitleCase(editValues.fullName) });
    setEditSaving(false);
    if (result.error) { setEditError(result.error); return; }
    setEditingId(null);
    onRefresh();
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-user-plus" style={{ color: 'var(--blue)' }}></i> Register Attendee</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 0.6fr 0.7fr', gap: 8, marginBottom: 10 }}>
          <input className="fi" placeholder="Full name*" value={fullName} onChange={(e) => setFullName(e.target.value)} onBlur={() => setFullName((v) => toTitleCase(v))} autoFocus />
          <input className="fi" placeholder="Phone*" value={phone} onChange={(e) => setPhone(e.target.value)} maxLength={10} />
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

      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g600)', marginBottom: 8 }}>Registered so far ({screenings.length}) -- click a row to fix a mistake</div>
      <table className="tbl">
        <thead><tr><th>Name</th><th>Phone</th><th>Age/Gender</th><th>Time</th><th></th></tr></thead>
        <tbody>
          {[...screenings].reverse().map((s) => (
            editingId === s.id ? (
              <tr key={s.id} style={{ background: 'var(--blue-lt)' }}>
                <td colSpan={5} style={{ padding: 10 }}>
                  <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 0.6fr 0.7fr auto auto', gap: 8, alignItems: 'center' }}>
                    <input className="fi fi-sm" value={editValues.fullName} onChange={(e) => setEditValues({ ...editValues, fullName: e.target.value })} onBlur={() => setEditValues((v) => ({ ...v, fullName: toTitleCase(v.fullName) }))} />
                    <input className="fi fi-sm" value={editValues.phone} onChange={(e) => setEditValues({ ...editValues, phone: e.target.value })} maxLength={10} />
                    <input className="fi fi-sm" value={editValues.age} onChange={(e) => setEditValues({ ...editValues, age: e.target.value })} />
                    <select className="fi fi-sm" value={editValues.gender} onChange={(e) => setEditValues({ ...editValues, gender: e.target.value })}>
                      <option value="M">Male</option><option value="F">Female</option><option value="O">Other</option>
                    </select>
                    <button className="btn btn-sm btn-primary" onClick={saveEdit} disabled={editSaving}><i className="ti ti-check"></i></button>
                    <button className="btn btn-sm" onClick={() => setEditingId(null)}><i className="ti ti-x"></i></button>
                  </div>
                  {editError && <div className="msg-err" style={{ marginTop: 8 }}>{editError}</div>}
                </td>
              </tr>
            ) : (
              <tr key={s.id} onClick={() => startEdit(s)} style={{ cursor: 'pointer' }}>
                <td>{s.full_name}</td>
                <td style={{ fontSize: 12 }}>{s.phone}</td>
                <td style={{ fontSize: 12 }}>{s.age || '--'}{s.gender ? `/${s.gender}` : ''}</td>
                <td style={{ fontSize: 11, color: 'var(--g400)' }}>{fmtTime(s.created_at)}</td>
                <td><i className="ti ti-pencil" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            )
          ))}
          {screenings.length === 0 && <tr><td colSpan={5} style={{ textAlign: 'center', padding: 20, color: 'var(--g400)' }}>No one registered yet.</td></tr>}
        </tbody>
      </table>
    </div>
  );
}

function initials(name) {
  const parts = (name || '').trim().split(/\s+/);
  return ((parts[0]?.[0] || '') + (parts[1]?.[0] || '')).toUpperCase();
}

// Section label inside the queue -- a colored dot + uppercase label +
// count, so "who's waiting" vs "who's already been seen" reads as two
// distinct zones at a glance, not just a color difference on each row.
function QueueSectionHeader({ label, count, color, withDivider }) {
  return (
    <div
      style={{
        display: 'flex', alignItems: 'center', gap: 7,
        fontSize: 10.5, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.06em',
        padding: withDivider ? '14px 4px 8px' : '2px 4px 8px',
        borderTop: withDivider ? '1px solid var(--g200)' : 'none',
        marginTop: withDivider ? 6 : 0,
      }}
    >
      <span style={{ width: 6, height: 6, borderRadius: '50%', background: color, flexShrink: 0 }}></span>
      {label}
      <span style={{ marginLeft: 'auto', color: 'var(--g400)' }}>{count}</span>
    </div>
  );
}

// One entry in the queue -- an initials avatar (a checkmark once
// seen), name, and context line. Left accent bar carries the state
// color even at a glance from across the room: gray for waiting,
// green for already seen, blue whenever selected (a done person is
// still reselectable to correct what was recorded).
function QueueRow({ s, selected, done, onClick, subtitle }) {
  return (
    <div
      onClick={onClick}
      className="queue-row"
      style={{
        display: 'flex', alignItems: 'center', gap: 10,
        padding: '9px 12px', borderRadius: 'var(--r)', marginBottom: 6, cursor: 'pointer',
        background: selected ? 'var(--blue-lt)' : '#fff',
        boxShadow: selected ? 'var(--shadow-md)' : 'var(--shadow-sm)',
        border: '1px solid', borderColor: selected ? 'var(--blue)' : 'var(--g200)',
        borderLeft: '4px solid', borderLeftColor: selected ? 'var(--blue)' : done ? 'var(--green)' : 'var(--g300)',
      }}
    >
      <div style={{
        width: 30, height: 30, borderRadius: '50%', flexShrink: 0,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontSize: 11, fontWeight: 700,
        background: done ? 'var(--green-lt)' : 'var(--g100)',
        color: done ? 'var(--green)' : 'var(--g600)',
      }}>
        {done ? <i className="ti ti-check" style={{ fontSize: 14 }}></i> : initials(s.full_name)}
      </div>
      <div style={{ minWidth: 0, flex: 1 }}>
        <div style={{ fontWeight: 600, fontSize: 13, color: 'var(--g800)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{s.full_name}</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{subtitle}</div>
      </div>
    </div>
  );
}

// ── STATION 2: EYE CHECKUP -- optometrist's room. Queue on the left
// (pending on top, already-checked below in green), selected person's
// form on the right. Picking an already-checked person re-opens their
// VA for correction instead of leaving a mistake stuck on record. ──
function EyeCheckupStation({ pending, done, onRefresh }) {
  const [selectedId, setSelectedId] = useState(null);
  const [vaOd, setVaOd] = useState('');
  const [vaOs, setVaOs] = useState('');
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const all = [...pending, ...done];
  const selected = all.find((s) => s.id === selectedId) || null;
  const wasPending = selected && !selected.eye_checkup_done_at;

  function pick(s) {
    setSelectedId(s.id);
    setVaOd(s.va_od || ''); setVaOs(s.va_os || ''); setNotes(s.optometrist_notes || '');
    setError('');
  }

  async function handleSave() {
    if (!vaOd.trim() && !vaOs.trim()) { setError('Enter at least one eye\u2019s VA.'); return; }
    setSaving(true);
    const result = await recordEyeCheckup(selected.id, { vaOd, vaOs, notes });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    // A fresh (pending) entry auto-advances to the next person waiting
    // -- keeps the optometrist moving through the line without an
    // extra click. Editing an already-done record just confirms and
    // drops back to the queue instead of implying there's a "next".
    if (wasPending) {
      const remaining = pending.filter((s) => s.id !== selected.id);
      if (remaining.length > 0) { pick(remaining[0]); onRefresh(); return; }
    }
    setSelectedId(null);
    onRefresh();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '300px 1fr', gap: 16, alignItems: 'flex-start' }}>
      <div style={{ background: 'var(--g50)', borderRadius: 'var(--r-lg)', padding: '10px 8px', maxHeight: 620, overflowY: 'auto' }}>
        <QueueSectionHeader label="Waiting" count={pending.length} color="var(--teal)" />
        {pending.map((s) => (
          <QueueRow key={s.id} s={s} selected={selectedId === s.id} done={false} onClick={() => pick(s)} subtitle={`${s.phone} -- ${s.age || '--'}${s.gender ? `/${s.gender}` : ''}`} />
        ))}
        {pending.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)', padding: '4px 4px 10px' }}>Everyone registered has been checked.</div>}

        <QueueSectionHeader label="Already Seen" count={done.length} color="var(--green)" withDivider />
        {done.map((s) => (
          <QueueRow key={s.id} s={s} selected={selectedId === s.id} done onClick={() => pick(s)} subtitle={`VA ${s.va_od || '--'} / ${s.va_os || '--'}`} />
        ))}
        {done.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)', padding: '4px 4px 6px' }}>None yet.</div>}

        {all.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 12 }}>No one registered yet.</div>}
      </div>

      <div className="card" style={{ boxShadow: 'var(--shadow-md)' }}>
        {!selected ? (
          <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>
            <i className="ti ti-eye" style={{ fontSize: 24, marginBottom: 8, display: 'block' }}></i>
            Select someone from the queue on the left.
          </div>
        ) : (
          <>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 16 }}>
              <div style={{ width: 42, height: 42, borderRadius: '50%', background: 'var(--teal-lt)', color: 'var(--teal)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 700, fontSize: 14, flexShrink: 0 }}>
                {initials(selected.full_name)}
              </div>
              <div>
                <div className="card-title" style={{ marginBottom: 1 }}>{selected.full_name}</div>
                <div style={{ fontSize: 12, color: 'var(--g500)' }}>{selected.phone} -- {selected.age || '--'}{selected.gender ? `/${selected.gender}` : ''}</div>
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10, maxWidth: 420 }}>
              <div><label className="flbl">VA -- Right eye (OD)</label><input className="fi" value={vaOd} onChange={(e) => setVaOd(e.target.value)} placeholder="e.g. 6/9" autoFocus /></div>
              <div><label className="flbl">VA -- Left eye (OS)</label><input className="fi" value={vaOs} onChange={(e) => setVaOs(e.target.value)} placeholder="e.g. 6/12" /></div>
            </div>
            <div style={{ maxWidth: 420, marginBottom: 14 }}>
              <label className="flbl">Notes <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(optional -- visible to the doctor)</span></label>
              <textarea className="fi" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="e.g. difficulty with pinhole, uncooperative child, wears glasses already..." />
            </div>
            {error && <div className="msg-err" style={{ marginBottom: 10, maxWidth: 420 }}>{error}</div>}
            <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
              <i className="ti ti-check"></i> {saving ? 'Saving...' : wasPending ? 'Save & Next' : 'Save Changes'}
            </button>
          </>
        )}
      </div>
    </div>
  );
}

// ── STATION 3: DOCTOR EXAM -- doctor's room. Same split-screen queue
// pattern, but only pulls from people who've cleared the eye checkup,
// and shows VA for context. Already-examined people are reselectable
// here too, to correct a finding. ──
function DoctorExamStation({ pending, done, onRefresh }) {
  const [selectedId, setSelectedId] = useState(null);
  const [finding, setFinding] = useState('');
  const [referralRecommended, setReferralRecommended] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const all = [...pending, ...done];
  const selected = all.find((s) => s.id === selectedId) || null;
  const wasPending = selected && !selected.doctor_reviewed_at;

  function pick(s) {
    setSelectedId(s.id);
    setFinding(s.finding || ''); setReferralRecommended(!!s.referral_recommended);
    setError('');
  }

  async function handleSave() {
    setSaving(true);
    const result = await recordDoctorExamination(selected.id, { finding, referralRecommended });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    if (wasPending) {
      const remaining = pending.filter((s) => s.id !== selected.id);
      if (remaining.length > 0) { pick(remaining[0]); onRefresh(); return; }
    }
    setSelectedId(null);
    onRefresh();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '300px 1fr', gap: 16, alignItems: 'flex-start' }}>
      <div style={{ background: 'var(--g50)', borderRadius: 'var(--r-lg)', padding: '10px 8px', maxHeight: 620, overflowY: 'auto' }}>
        <QueueSectionHeader label="Waiting" count={pending.length} color="var(--indigo)" />
        {pending.map((s) => (
          <QueueRow key={s.id} s={s} selected={selectedId === s.id} done={false} onClick={() => pick(s)} subtitle={`${s.phone} -- VA ${s.va_od || '--'}/${s.va_os || '--'}`} />
        ))}
        {pending.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)', padding: '4px 4px 10px' }}>Nobody's waiting on you right now.</div>}

        <QueueSectionHeader label="Already Seen" count={done.length} color="var(--green)" withDivider />
        {done.map((s) => (
          <QueueRow key={s.id} s={s} selected={selectedId === s.id} done onClick={() => pick(s)} subtitle={s.referral_recommended ? 'Referral recommended' : (s.finding || 'No issues noted')} />
        ))}
        {done.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)', padding: '4px 4px 6px' }}>None yet.</div>}

        {all.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 12 }}>No one's cleared the eye checkup yet.</div>}
      </div>

      <div className="card" style={{ boxShadow: 'var(--shadow-md)' }}>
        {!selected ? (
          <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>
            <i className="ti ti-stethoscope" style={{ fontSize: 24, marginBottom: 8, display: 'block' }}></i>
            Select someone from the queue on the left.
          </div>
        ) : (
          <>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, marginBottom: 12 }}>
              <div style={{ width: 42, height: 42, borderRadius: '50%', background: 'var(--indigo-lt)', color: 'var(--indigo)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 700, fontSize: 14, flexShrink: 0 }}>
                {initials(selected.full_name)}
              </div>
              <div style={{ flex: 1 }}>
                <div className="card-title" style={{ marginBottom: 1 }}>{selected.full_name}</div>
                <div style={{ fontSize: 12, color: 'var(--g500)' }}>{selected.phone} -- {selected.age || '--'}{selected.gender ? `/${selected.gender}` : ''}</div>
              </div>
              {/* tel: opens the device's own dialer with the number
                  pre-filled -- for when a finding needs a quick word
                  with the patient right then, not a WhatsApp message
                  that might not be seen for hours. */}
              <a
                href={`tel:+91${selected.phone.replace(/\D/g, '')}`}
                className="btn btn-sm"
                style={{ background: 'var(--green)', color: '#fff', border: 'none', textDecoration: 'none', flexShrink: 0 }}
              >
                <i className="ti ti-phone-call"></i> Call
              </a>
            </div>

            <div style={{ display: 'flex', gap: 8, marginBottom: 14, flexWrap: 'wrap' }}>
              <div style={{ fontSize: 12.5, background: 'var(--g50)', borderRadius: 8, padding: '6px 10px' }}>
                VA: OD {selected.va_od || '--'} / OS {selected.va_os || '--'}
              </div>
              {selected.optometrist_notes && (
                <div style={{ fontSize: 12.5, background: 'var(--teal-lt)', color: 'var(--teal)', borderRadius: 8, padding: '6px 10px' }}>
                  <i className="ti ti-notes"></i> {selected.optometrist_notes}
                </div>
              )}
            </div>

            <div style={{ maxWidth: 460 }}>
              <label className="flbl">Finding</label>
              <textarea className="fi" rows={2} style={{ marginBottom: 10 }} value={finding} onChange={(e) => setFinding(e.target.value)} placeholder="e.g. possible cataract, high refractive error, normal..." autoFocus />
              <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12.5, cursor: 'pointer', marginBottom: 14 }}>
                <input type="checkbox" checked={referralRecommended} onChange={(e) => setReferralRecommended(e.target.checked)} />
                Recommend a hospital visit for detailed checkup
              </label>
              {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}
              <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
                <i className="ti ti-check"></i> {saving ? 'Saving...' : wasPending ? 'Save & Next' : 'Save Changes'}
              </button>
            </div>
          </>
        )}
      </div>
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
