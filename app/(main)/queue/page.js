'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import {
  getQueues,
  optometryCallNext,
  optometryCallSpecific,
  doctorCallNext,
  doctorCallSpecific,
  doctorMarkReady,
} from './actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

function TokenBadge({ token }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
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
    if (result?.error) setError(result.error);
    refresh();
  }

  const doctorInConsultation = doctor.find((d) => d.status === 'In Consultation');

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* OPTOMETRY */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Queue
              <span className="badge b-gray">{optometry.length}</span>
            </div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>
          {optometry.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
                background: e.status === 'Calling' ? 'var(--blue-lt)' : 'transparent',
              }}
            >
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Calling' ? 'b-blue' : 'b-gray'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}>
                    <i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m
                  </span>
                </div>
              </div>
              {e.status === 'Waiting' && (
                <button className="btn btn-sm" onClick={() => runAction(optometryCallSpecific, e.id)}>Call</button>
              )}
              {e.status === 'Calling' && (
                <Link href={`/optometry/${e.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                  Enter Findings
                </Link>
              )}
            </div>
          ))}
          {optometry.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* DOCTOR */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue
              <span className="badge b-gray">{doctor.length}</span>
            </div>
          </div>
          <button
            className="btn btn-primary"
            style={{ width: '100%', marginBottom: 12 }}
            onClick={() => runAction(doctorCallNext)}
            disabled={!!doctorInConsultation}
          >
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>

          {doctorInConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                <TokenBadge token={doctorInConsultation.token} />
                <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(doctorInConsultation)}</span>
              </div>
              <Link
                href={`/consultation/${doctorInConsultation.id}`}
                className="btn btn-primary btn-sm"
                style={{ textDecoration: 'none' }}
              >
                <i className="ti ti-clipboard-text"></i> Open Consultation
              </Link>
            </div>
          )}

          {doctor
            .filter((e) => e.id !== doctorInConsultation?.id)
            .map((e) => {
              // startsWith('Awaiting') catches every sent-out destination,
              // including compound statuses like "Awaiting Investigation &
              // Biometry" when a patient's been sent for more than one
              // thing at once -- an exact-match list would miss those.
              const notAvailable = e.status?.startsWith('Awaiting');
              const since = notAvailable ? e.sent_out_at : e.issued_at;
              return (
                <div
                  key={e.id}
                  style={{
                    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                    padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
                    opacity: notAvailable ? 0.55 : 1,
                  }}
                >
                  <div>
                    <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                      <TokenBadge token={e.token} />
                      <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                    </div>
                    <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                      <span className={`badge ${notAvailable ? 'b-amber' : 'b-gray'}`}>{e.status}</span>
                      <span className={`badge ${waitBadgeClass(elapsedMin(since))}`}>
                        <i className="ti ti-clock"></i> {elapsedMin(since)}m
                      </span>
                    </div>
                  </div>
                  {(e.status === 'Waiting' || e.status === 'Ready for Review') && (
                    <button className="btn btn-sm" onClick={() => runAction(doctorCallSpecific, e.id)} disabled={!!doctorInConsultation}>
                      Call
                    </button>
                  )}
                  {notAvailable && (
                    <button className="btn btn-sm" onClick={() => runAction(doctorMarkReady, e.id)}>Mark Ready</button>
                  )}
                </div>
              );
            })}
          {doctor.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>
      </div>
    </div>
  );
}


