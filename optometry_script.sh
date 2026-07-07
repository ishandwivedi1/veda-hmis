mkdir -p 'app/optometry/[id]' app/queue

cat > 'app/optometry/actions.js' << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

export async function getQueueEntryForOptometry(queueEntryId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (error) return { error: error.message };
  return { entry: data };
}

export async function saveFindingsAndComplete(queueEntryId, visitId, findings) {
  const supabase = await createClient();

  const { data: userData } = await supabase.auth.getUser();

  const { error: findingsError } = await supabase.from('optometry_findings').insert({
    visit_id: visitId,
    re_va: findings.reVa || null,
    le_va: findings.leVa || null,
    re_iop: findings.reIop ? parseFloat(findings.reIop) : null,
    le_iop: findings.leIop ? parseFloat(findings.leIop) : null,
    re_sph: findings.reSph || null,
    le_sph: findings.leSph || null,
    re_cyl: findings.reCyl || null,
    le_cyl: findings.leCyl || null,
    recorded_by: userData?.user?.id || null,
  });

  if (findingsError) {
    return { error: findingsError.message };
  }

  const { error: completeError } = await supabase.rpc('optometry_complete', {
    p_queue_entry_id: queueEntryId,
  });

  if (completeError) {
    return { error: completeError.message };
  }

  return { success: true };
}

EOF

cat > 'app/optometry/[id]/page.js' << 'EOF'
import OptometryForm from './optometry-form';

export default async function OptometryEntryPage({ params }) {
  const { id } = await params;
  return <OptometryForm queueEntryId={id} />;
}

EOF

cat > 'app/optometry/[id]/optometry-form.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getQueueEntryForOptometry, saveFindingsAndComplete } from '../actions';

export default function OptometryForm({ queueEntryId }) {
  const [entry, setEntry] = useState(null);
  const [loadError, setLoadError] = useState('');

  const [reVa, setReVa] = useState('');
  const [leVa, setLeVa] = useState('');
  const [reIop, setReIop] = useState('');
  const [leIop, setLeIop] = useState('');
  const [reSph, setReSph] = useState('');
  const [leSph, setLeSph] = useState('');
  const [reCyl, setReCyl] = useState('');
  const [leCyl, setLeCyl] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getQueueEntryForOptometry(queueEntryId).then((result) => {
      if (result.error) {
        setLoadError(result.error);
      } else {
        setEntry(result.entry);
      }
    });
  }, [queueEntryId]);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    const result = await saveFindingsAndComplete(queueEntryId, entry.visits.id, {
      reVa, leVa, reIop, leIop, reSph, leSph, reCyl, leCyl,
    });

    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/queue');
  }

  if (loadError) {
    return (
      <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
        <div className="msg-err">{loadError}</div>
      </div>
    );
  }

  if (!entry) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = entry.visits?.patients;

  return (
    <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          Optometry -- {entry.token}
        </div>
        <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 20 }}>
          {patient?.first_name} {patient?.last_name} -- {patient?.uhid} -- {patient?.age} {patient?.gender}
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
            Visual Acuity
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
            <div>
              <label className="flbl">RE VA</label>
              <input className="fi" value={reVa} onChange={(e) => setReVa(e.target.value)} placeholder="e.g. 6/9" />
            </div>
            <div>
              <label className="flbl">LE VA</label>
              <input className="fi" value={leVa} onChange={(e) => setLeVa(e.target.value)} placeholder="e.g. 6/12" />
            </div>
          </div>

          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
            IOP (mmHg)
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
            <div>
              <label className="flbl">RE IOP</label>
              <input type="number" className="fi" value={reIop} onChange={(e) => setReIop(e.target.value)} />
            </div>
            <div>
              <label className="flbl">LE IOP</label>
              <input type="number" className="fi" value={leIop} onChange={(e) => setLeIop(e.target.value)} />
            </div>
          </div>

          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
            Refraction
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr', gap: 8, marginBottom: 20 }}>
            <div>
              <label className="flbl">RE Sph</label>
              <input className="fi" value={reSph} onChange={(e) => setReSph(e.target.value)} placeholder="-2.00" />
            </div>
            <div>
              <label className="flbl">RE Cyl</label>
              <input className="fi" value={reCyl} onChange={(e) => setReCyl(e.target.value)} placeholder="-0.50" />
            </div>
            <div>
              <label className="flbl">LE Sph</label>
              <input className="fi" value={leSph} onChange={(e) => setLeSph(e.target.value)} placeholder="-1.50" />
            </div>
            <div>
              <label className="flbl">LE Cyl</label>
              <input className="fi" value={leCyl} onChange={(e) => setLeCyl(e.target.value)} placeholder="-0.25" />
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Saving...' : 'Save & Complete -- Send to Doctor'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/queue')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

EOF

cat > 'app/queue/page.js' << 'EOF'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import {
  getQueues,
  optometryCallNext,
  optometryCallSpecific,
  doctorCallNext,
  doctorCallSpecific,
  doctorComplete,
  doctorSendOut,
  doctorMarkReady,
} from './actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export default function QueuePage() {
  const [optometry, setOptometry] = useState([]);
  const [doctor, setDoctor] = useState([]);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const { optometry, doctor } = await getQueues();
    setOptometry(optometry);
    setDoctor(doctor);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) {
      setError(result.error);
    }
    refresh();
  }

  const doctorInConsultation = doctor.find((d) => d.status === 'In Consultation');

  return (
    <div style={{ maxWidth: 1100, margin: '40px auto', padding: '0 20px' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 16 }}>Queue Management</div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* OPTOMETRY */}
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <div style={{ fontSize: 15, fontWeight: 700 }}>Optometry Queue</div>
            <span style={{ fontSize: 12, color: 'var(--g500)' }}>{optometry.length}</span>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
            Call Next
          </button>
          {optometry.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                padding: '10px 0',
                borderBottom: '1px solid var(--g100)',
                background: e.status === 'Calling' ? 'var(--blue-lt)' : 'transparent',
              }}
            >
              <div>
                <div style={{ fontWeight: 700, fontSize: 13 }}>
                  {e.token} -- {patientName(e)}
                </div>
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                  {e.status} -- waiting {elapsedMin(e.issued_at)} min
                </div>
              </div>
              {e.status === 'Waiting' && (
                <button className="btn" style={{ padding: '4px 10px', fontSize: 12 }} onClick={() => runAction(optometryCallSpecific, e.id)}>
                  Call
                </button>
              )}
              {e.status === 'Calling' && (
                <Link href={`/optometry/${e.id}`} className="btn btn-primary" style={{ padding: '4px 10px', fontSize: 12, textDecoration: 'none' }}>
                  Enter Findings
                </Link>
              )}
            </div>
          ))}
          {optometry.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 20 }}>Empty</div>
          )}
        </div>

        {/* DOCTOR */}
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <div style={{ fontSize: 15, fontWeight: 700 }}>Doctor Queue</div>
            <span style={{ fontSize: 12, color: 'var(--g500)' }}>{doctor.length}</span>
          </div>
          <button
            className="btn btn-primary"
            style={{ width: '100%', marginBottom: 12 }}
            onClick={() => runAction(doctorCallNext)}
            disabled={!!doctorInConsultation}
          >
            Call Next
          </button>

          {doctorInConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ fontWeight: 700, fontSize: 14 }}>
                {doctorInConsultation.token} -- {patientName(doctorInConsultation)}
              </div>
              <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
                <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => runAction(doctorComplete, doctorInConsultation.id)}>
                  Complete Visit
                </button>
                <button className="btn" style={{ fontSize: 12 }} onClick={() => runAction(doctorSendOut, doctorInConsultation.id, 'dilate')}>
                  Send for Dilation
                </button>
                <button className="btn" style={{ fontSize: 12 }} onClick={() => runAction(doctorSendOut, doctorInConsultation.id, 'investigate')}>
                  Send for Investigation
                </button>
              </div>
            </div>
          )}

          {doctor
            .filter((e) => e.id !== doctorInConsultation?.id)
            .map((e) => {
              const notAvailable = e.status === 'Awaiting Dilation' || e.status === 'Awaiting Investigation';
              const since = notAvailable ? e.sent_out_at : e.issued_at;
              return (
                <div
                  key={e.id}
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    padding: '10px 0',
                    borderBottom: '1px solid var(--g100)',
                    opacity: notAvailable ? 0.6 : 1,
                  }}
                >
                  <div>
                    <div style={{ fontWeight: 700, fontSize: 13 }}>
                      {e.token} -- {patientName(e)}
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                      {e.status} -- {elapsedMin(since)} min
                    </div>
                  </div>
                  {(e.status === 'Waiting' || e.status === 'Ready for Review') && (
                    <button
                      className="btn"
                      style={{ padding: '4px 10px', fontSize: 12 }}
                      onClick={() => runAction(doctorCallSpecific, e.id)}
                      disabled={!!doctorInConsultation}
                    >
                      Call
                    </button>
                  )}
                  {notAvailable && (
                    <button className="btn" style={{ padding: '4px 10px', fontSize: 12 }} onClick={() => runAction(doctorMarkReady, e.id)}>
                      Mark Ready
                    </button>
                  )}
                </div>
              );
            })}
          {doctor.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 20 }}>Empty</div>
          )}
        </div>
      </div>
    </div>
  );
}

EOF

echo "Optometry module created."
