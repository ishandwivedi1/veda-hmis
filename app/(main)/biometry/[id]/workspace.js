'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryDetail } from '../actions';
import MeasurementsTab from './measurements-tab';
import CalculationTab from './calculation-tab';
import ApprovalTab from './approval-tab';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function BiometryWorkspace({ recordId }) {
  const [record, setRecord] = useState(null);
  const [surgeonName, setSurgeonName] = useState('--');
  const [loadError, setLoadError] = useState('');
  const [activeTab, setActiveTab] = useState('measurements');
  const router = useRouter();

  async function refresh() {
    const result = await getBiometryDetail(recordId);
    if (result.error) { setLoadError(result.error); return; }
    setRecord(result.record);
    setSurgeonName(result.surgeonName);
  }

  useEffect(() => { refresh(); }, [recordId]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = record.visits?.patients;
  const visitNumber = record.visits?.visit_number;
  const isVerified = record.status === 'Calculated' || record.status === 'Approved';
  const isApproved = record.status === 'Approved';

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#4338ca)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Visit {visitNumber || '--'} -- Dr. {surgeonName}</div>
        </div>
        <span className="badge" style={{ background: isApproved ? 'rgba(34,197,94,.35)' : isVerified ? 'rgba(99,102,241,.3)' : 'rgba(255,255,255,.15)', color: isApproved || isVerified ? '#fff' : '#fff', fontSize: 11 }}>
          {record.status}
        </span>
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
        <TabButton active={activeTab === 'measurements'} onClick={() => setActiveTab('measurements')} icon="ti-ruler-measure" label="Measurements" />
        <TabButton active={activeTab === 'calculation'} onClick={() => setActiveTab('calculation')} icon="ti-calculator" label="IOL Calculation" disabled={!isVerified} />
        <TabButton active={activeTab === 'approval'} onClick={() => setActiveTab('approval')} icon="ti-shield-check" label="Surgeon Approval" disabled={!isVerified} />
      </div>

      {activeTab === 'measurements' && <MeasurementsTab record={record} recordId={recordId} onSaved={refresh} />}
      {activeTab === 'calculation' && <CalculationTab record={record} recordId={recordId} onSaved={refresh} />}
      {activeTab === 'approval' && <ApprovalTab record={record} recordId={recordId} surgeonName={surgeonName} onSaved={refresh} />}

      <div style={{ marginTop: 16 }}>
        <button className="btn" onClick={() => router.push('/biometry')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
}
