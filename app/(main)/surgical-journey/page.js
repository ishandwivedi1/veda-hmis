'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getMyActiveSurgicalCases, getAwaitingReturnCases, getDischargedTodaySurgicalCases, getCompletedSurgicalCases, recordManualReminder } from './actions';

const STAGE_LABEL = {
  'Pending Workup': 'Working Up',
  'Ready for Scheduling': 'Ready to Book',
  Scheduled: 'Scheduled',
};
const STAGE_BADGE = {
  'Pending Workup': 'b-amber',
  'Ready for Scheduling': 'b-blue',
  Scheduled: 'b-green',
};

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--indigo)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function daysAgo(dateStr) {
  const diff = Date.now() - new Date(dateStr).getTime();
  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  if (days <= 0) return 'today';
  if (days === 1) return '1 day ago';
  return `${days} days ago`;
}

function ReminderModal({ caseRow, onClose, onDone }) {
  const [note, setNote] = useState('');
  const [saving, setSaving] = useState(false);

  async function handleSave() {
    setSaving(true);
    await recordManualReminder(caseRow.id, note);
    setSaving(false);
    onDone();
  }

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }} onClick={onClose}>
      <div className="card" style={{ width: 380, maxWidth: '90vw' }} onClick={(e) => e.stopPropagation()}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-phone-call" style={{ color: 'var(--blue)' }}></i> Log Follow-up Call
        </div>
        <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 10 }}>
          {caseRow.patients?.first_name} {caseRow.patients?.last_name} -- {caseRow.patients?.mobile}
        </div>
        <textarea
          className="fi" rows={3} placeholder="What did they say? e.g. 'Will come next week', 'No answer', 'Decided against it'..."
          value={note} onChange={(e) => setNote(e.target.value)} style={{ marginBottom: 12 }}
        />
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button className="btn" onClick={onClose}>Cancel</button>
          <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
            {saving ? 'Saving...' : 'Log Call'}
          </button>
        </div>
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((c) => {
        const q = search.trim().toLowerCase();
        return `${c.patients?.first_name} ${c.patients?.last_name}`.toLowerCase().includes(q) || (c.patients?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed / Cancelled Cases <span className="badge b-gray" style={{ marginLeft: 8 }}>{rows.length}</span></div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Cases that have finished the journey (discharged) or been cancelled -- Active Cases only shows cases still in progress, including surgeries done but not yet discharged.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && filtered.map((c) => (
        <div key={c.id} onClick={() => onOpen(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
          <div style={{ width: 34, height: 34, borderRadius: '50%', background: c.status === 'Cancelled' ? 'var(--g400)' : 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
            {c.patients?.first_name?.charAt(0)}
          </div>
          <div style={{ flex: 1 }}>
            <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
            <span className={`badge ${c.status === 'Cancelled' ? 'b-gray' : 'b-green'}`} style={{ marginLeft: 8, fontSize: 10 }}>{c.status}</span>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
              {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye}{c.master_packages ? ` -- ${c.master_packages.name}` : ''}
            </div>
          </div>
          <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
        </div>
      ))}
      {!loading && filtered.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No completed or cancelled cases yet.</div>
      )}
    </div>
  );
}

export default function SurgicalJourneyPage() {
  const [activeTab, setActiveTab] = useState('active');
  const [cases, setCases] = useState([]);
  const [awaiting, setAwaiting] = useState([]);
  const [dischargedToday, setDischargedToday] = useState([]);
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadingDischargedToday, setLoadingDischargedToday] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [reminderFor, setReminderFor] = useState(null);
  const router = useRouter();

  const refresh = useCallback(async () => {
    setCases(await getMyActiveSurgicalCases());
    setAwaiting(await getAwaitingReturnCases());
    setLoading(false);
  }, []);
  const refreshDischargedToday = useCallback(async () => {
    setDischargedToday(await getDischargedTodaySurgicalCases());
    setLoadingDischargedToday(false);
  }, []);
  const refreshHistory = useCallback(async () => {
    setHistory(await getCompletedSurgicalCases());
    setLoadingHistory(false);
  }, []);

  useEffect(() => { refresh(); refreshDischargedToday(); refreshHistory(); }, [refresh, refreshDischargedToday, refreshHistory]);

  const proceeding = cases.filter((c) => c.decision !== 'Wants Time to Decide' && c.decision !== 'Declined');

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
        <div>
          <div style={{ fontSize: 18, fontWeight: 700 }}>Surgical Journey</div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>Every active surgical case, one page each, start to discharge.</div>
        </div>
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
        <TabButton active={activeTab === 'active'} onClick={() => setActiveTab('active')} icon="ti-list-numbers" label="Active Cases" />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="Completed / History" />
      </div>

      {activeTab === 'active' && (
        <>
          {awaiting.length > 0 && (
            <div className="card" style={{ marginBottom: 16, borderColor: 'var(--amber)' }}>
              <div className="card-title" style={{ marginBottom: 4 }}>
                <i className="ti ti-clock-pause" style={{ color: 'var(--amber)' }}></i> Awaiting Return
                <span className="badge b-amber" style={{ marginLeft: 8 }}>{awaiting.length}</span>
              </div>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
                Advised surgery, said they'd come back another day. Worth a call if it's been a while.
              </div>
              {awaiting.map((c) => (
                <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                    {c.patients?.first_name?.charAt(0)}
                  </div>
                  <div style={{ flex: 1, cursor: 'pointer' }} onClick={() => router.push(`/surgical-journey/${c.id}`)}>
                    <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
                    <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>Advised {daysAgo(c.created_at)}</span>
                    {c.reminder_count > 0 && <span className="badge b-blue" style={{ marginLeft: 6, fontSize: 10 }}>{c.reminder_count} call{c.reminder_count > 1 ? 's' : ''} logged</span>}
                    <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                      {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye} -- {c.patients?.mobile}
                    </div>
                  </div>
                  <button className="btn btn-sm" onClick={() => setReminderFor(c)}>
                    <i className="ti ti-phone-call"></i> Log Call
                  </button>
                  <button className="btn btn-sm btn-primary" onClick={() => router.push(`/surgical-journey/${c.id}`)}>
                    Open
                  </button>
                </div>
              ))}
            </div>
          )}

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Active Cases
              <span className="badge b-gray" style={{ marginLeft: 8 }}>{proceeding.length}</span>
            </div>
            {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
            {!loading && proceeding.map((c) => (
              <div key={c.id} onClick={() => router.push(`/surgical-journey/${c.id}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
                <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                  {c.patients?.first_name?.charAt(0)}
                </div>
                <div style={{ flex: 1 }}>
                  <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
                  <span className={`badge ${STAGE_BADGE[c.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{STAGE_LABEL[c.status] || c.status}</span>
                  <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                    {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye}{c.master_packages ? ` -- ${c.master_packages.name}` : ''}
                  </div>
                </div>
                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
              </div>
            ))}
            {!loading && proceeding.length === 0 && (
              <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No active surgical cases right now.</div>
            )}
          </div>

          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-title" style={{ marginBottom: 4 }}>
              <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Discharged / Completed Today
              <span className="badge b-green" style={{ marginLeft: 8 }}>{dischargedToday.length}</span>
            </div>
            <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>Moves to Completed / History tomorrow -- still open here today for reference.</div>
            {loadingDischargedToday && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Loading...</div>}
            {!loadingDischargedToday && dischargedToday.map((c) => (
              <div key={c.id} onClick={() => router.push(`/surgical-journey/${c.id}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
                <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                  {c.patients?.first_name?.charAt(0)}
                </div>
                <div style={{ flex: 1 }}>
                  <span style={{ fontWeight: 700, fontSize: 13 }}>{c.patients?.first_name} {c.patients?.last_name}</span>
                  <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>Discharged</span>
                  <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                    {c.surgery_code ? `${c.surgery_code} -- ` : ''}{c.patients?.uhid} -- {c.procedure_name} -- {c.eye}{c.master_packages ? ` -- ${c.master_packages.name}` : ''}
                  </div>
                </div>
                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
              </div>
            ))}
            {!loadingDischargedToday && dischargedToday.length === 0 && (
              <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nobody discharged yet today.</div>
            )}
          </div>
        </>
      )}

      {activeTab === 'history' && (
        <HistoryTab rows={history} loading={loadingHistory} onOpen={(id) => router.push(`/surgical-journey/${id}`)} />
      )}

      {reminderFor && (
        <ReminderModal
          caseRow={reminderFor}
          onClose={() => setReminderFor(null)}
          onDone={() => { setReminderFor(null); refresh(); }}
        />
      )}
    </div>
  );
}
