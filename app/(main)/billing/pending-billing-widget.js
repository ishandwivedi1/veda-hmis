'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingInvestigationBilling, markInvestigationDenied, markInvestigationDeferred, resetInvestigationBilling } from '@/app/(main)/investigation/actions';
import { getPendingProcedureBilling } from '@/app/(main)/billing/actions';
import { getPendingPrescriptionsForFrontOffice, markPrescriptionDenied, markPrescriptionDeferred, resetPrescriptionBilling } from '@/app/(main)/pharmacy/actions';
import { getPendingBiometryBilling, markBiometryDenied, markBiometryDeferred, resetBiometryBilling } from '@/app/(main)/biometry/actions';

const BILLING_BADGE = { Pending: 'b-amber', Deferred: 'b-indigo' };

const TYPE_META = {
  Investigation: { icon: 'ti-flask', color: 'var(--teal)' },
  Procedure: { icon: 'ti-tool', color: 'var(--blue)' },
  Pharmacy: { icon: 'ti-pill', color: 'var(--purple)' },
  Biometry: { icon: 'ti-ruler-measure', color: 'var(--indigo)' },
};

// One row of items within a patient's card for a single pending-billing
// type (e.g. their pending investigations). Handles its own defer/deny/
// reset actions where that type supports them.
function TypeSection({ type, group, busyId, onDefer, onDeny, onReset, onBillNow, renderItem }) {
  const meta = TYPE_META[type];
  return (
    <div style={{ marginTop: 8, paddingTop: 8, borderTop: '1px dashed var(--g200)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
        <span style={{ fontSize: 11, fontWeight: 700, color: meta.color }}>
          <i className={`ti ${meta.icon}`}></i> {type}
        </span>
        <button className="btn btn-sm" style={{ fontSize: 10, padding: '2px 8px' }} onClick={() => onBillNow(group)}>
          <i className="ti ti-receipt"></i> Bill Now
        </button>
      </div>
      {group.items.map((item) => (
        <div key={item.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12, flexWrap: 'wrap', gap: 4 }}>
          <div>
            {renderItem(item)}
            {item.billing_status && <span className={`badge ${BILLING_BADGE[item.billing_status] || 'b-amber'}`} style={{ marginLeft: 6, fontSize: 9 }}>{item.billing_status}</span>}
          </div>
          {item.billing_status && (
            <div style={{ display: 'flex', gap: 4 }}>
              {item.billing_status === 'Pending' && onDefer && (
                <>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === item.id} onClick={() => onDefer(item.id)}>
                    <i className="ti ti-clock"></i>
                  </button>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10, color: 'var(--red)' }} disabled={busyId === item.id} onClick={() => onDeny(item.id)}>
                    <i className="ti ti-x"></i>
                  </button>
                </>
              )}
              {item.billing_status === 'Deferred' && onReset && (
                <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === item.id} onClick={() => onReset(item.id)}>
                  Reset
                </button>
              )}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

export default function PendingBillingWidget() {
  const [investigations, setInvestigations] = useState([]);
  const [procedures, setProcedures] = useState([]);
  const [pharmacy, setPharmacy] = useState([]);
  const [biometry, setBiometry] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState(null);
  const router = useRouter();

  const load = useCallback(async () => {
    const [inv, proc, rx, bio] = await Promise.all([
      getPendingInvestigationBilling(),
      getPendingProcedureBilling(),
      getPendingPrescriptionsForFrontOffice(),
      getPendingBiometryBilling(),
    ]);
    setInvestigations(inv);
    setProcedures(proc);
    setPharmacy(rx);
    setBiometry(bio);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  async function withBusy(id, fn) {
    setBusyId(id);
    await fn(id);
    await load();
    setBusyId(null);
  }

  // Group everything by patient id -- package billing has no visitId, so
  // patient id is the only key common to all five sources.
  const byPatient = {};
  function ensurePatient(patient) {
    if (!patient?.id) return null;
    if (!byPatient[patient.id]) byPatient[patient.id] = { patient, types: {} };
    return byPatient[patient.id];
  }

  investigations.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Investigation = g; });
  procedures.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Procedure = g; });
  pharmacy.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Pharmacy = g; });
  biometry.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Biometry = g; });

  const patients = Object.values(byPatient);
  const totalItems = patients.reduce((s, p) => s + Object.values(p.types).reduce((s2, g) => s2 + g.items.length, 0), 0);

  function billNowFor(type, group) {
    const ids = group.items.map((i) => i.id).join(',');
    const param = { Investigation: 'invOrderIds', Procedure: 'procIds', Pharmacy: 'rxIds', Biometry: 'bioIds' }[type];
    router.push(`/billing/new?visitId=${group.visitId}&${param}=${ids}`);
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 4, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
        <span><i className="ti ti-clipboard-list" style={{ color: 'var(--red)' }}></i> Pending Billing</span>
        {totalItems > 0 && <span className="badge b-red">{totalItems}</span>}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
        Everything prescribed or recommended for a patient, not yet billed -- grouped by patient across investigations, procedures, pharmacy, biometry, and packages.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && patients.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- everything is billed.</div>
      )}

      {!loading && patients.map(({ patient, types }) => (
        <div key={patient.id} style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
            <div style={{ fontWeight: 600, fontSize: 13 }}>{patient.first_name} {patient.last_name}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{patient.uhid}</div>
            <div style={{ display: 'flex', gap: 4, marginLeft: 'auto' }}>
              {Object.keys(types).map((type) => (
                <span key={type} className="badge" style={{ background: `${TYPE_META[type].color}20`, color: TYPE_META[type].color, fontSize: 9 }}>{type}</span>
              ))}
            </div>
          </div>

          {types.Investigation && (
            <TypeSection
              type="Investigation" group={types.Investigation} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markInvestigationDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markInvestigationDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetInvestigationBilling)}
              onBillNow={(g) => billNowFor('Investigation', g)}
              renderItem={(io) => <>{io.name} <span style={{ color: 'var(--g400)' }}>({io.eye})</span></>}
            />
          )}
          {types.Procedure && (
            <TypeSection
              type="Procedure" group={types.Procedure} busyId={busyId}
              onBillNow={(g) => billNowFor('Procedure', g)}
              renderItem={(p) => <>{p.name} <span style={{ color: 'var(--g400)' }}>({p.eye})</span>{p.notes && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{p.notes}</div>}</>}
            />
          )}
          {types.Pharmacy && (
            <TypeSection
              type="Pharmacy" group={types.Pharmacy} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markPrescriptionDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markPrescriptionDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetPrescriptionBilling)}
              onBillNow={(g) => billNowFor('Pharmacy', g)}
              renderItem={(rx) => <>{rx.drug_name} <span style={{ color: 'var(--g400)' }}>({rx.eye})</span></>}
            />
          )}
          {types.Biometry && (
            <TypeSection
              type="Biometry" group={types.Biometry} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markBiometryDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markBiometryDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetBiometryBilling)}
              onBillNow={(g) => billNowFor('Biometry', g)}
              renderItem={() => <>Biometry</>}
            />
          )}
        </div>
      ))}
    </div>
  );
}
