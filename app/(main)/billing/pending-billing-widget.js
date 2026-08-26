'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingInvestigationBilling, markInvestigationDenied, markInvestigationDeferred, resetInvestigationBilling } from '@/app/(main)/investigation/actions';
import { getPendingProcedureBilling } from '@/app/(main)/billing/actions';
import { getPendingPrescriptionsForFrontOffice, markPrescriptionDenied, markPrescriptionDeferred, resetPrescriptionBilling } from '@/app/(main)/pharmacy/actions';
import { getPendingBiometryBilling, markBiometryDenied, markBiometryDeferred, resetBiometryBilling } from '@/app/(main)/biometry/actions';

const BILLING_BADGE = { Pending: 'b-amber', Deferred: 'b-indigo' };

// type key -> billNowFor's URL param, plus the section's own heading/
// icon/color -- title is the label shown to the person, which for
// Procedure is "Consultation" since that's what it actually reads as
// to front-office staff (a doctor's in-consultation procedure).
const CATEGORY_META = {
  Investigation: { title: 'Investigation Billing', icon: 'ti-flask', color: 'var(--teal)', param: 'invOrderIds' },
  Procedure: { title: 'OPD Procedure Billing', icon: 'ti-tool', color: 'var(--blue)', param: 'procIds' },
  Pharmacy: { title: 'Pharmacy Billing', icon: 'ti-pill', color: 'var(--purple)', param: 'rxIds' },
  Biometry: { title: 'Biometry Billing', icon: 'ti-ruler-measure', color: 'var(--indigo)', param: 'bioIds' },
};

// One row's worth of items for a single patient within a category --
// each item shown with its own defer/deny/reset controls where the
// category supports them, and one Bill Now button for the whole group
// (matches how Surgery Billing bills the whole package in one click).
function ItemsCell({ items, renderItem, busyId, onDefer, onDeny, onReset }) {
  return (
    <>
      {items.map((item) => (
        <div key={item.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8, padding: '2px 0', flexWrap: 'wrap' }}>
          <div>
            {renderItem(item)}
            {item.billing_status && <span className={`badge ${BILLING_BADGE[item.billing_status] || 'b-amber'}`} style={{ marginLeft: 6, fontSize: 9 }}>{item.billing_status}</span>}
          </div>
          {item.billing_status && (
            <div style={{ display: 'flex', gap: 4 }}>
              {item.billing_status === 'Pending' && onDefer && (
                <>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === item.id} onClick={() => onDefer(item.id)} title="Defer">
                    <i className="ti ti-clock"></i>
                  </button>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10, color: 'var(--red)' }} disabled={busyId === item.id} onClick={() => onDeny(item.id)} title="Deny">
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
    </>
  );
}

// A single category's pending-billing table, laid out the same way as
// the Billing Dashboard's Surgery Billing table: one row per patient,
// a details column, and a Bill Now button in the last column.
function CategoryTable({ type, groups, busyId, onDefer, onDeny, onReset, onBillNow, renderItem }) {
  const meta = CATEGORY_META[type];
  if (groups.length === 0) return null;

  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>
        <i className={`ti ${meta.icon}`} style={{ color: meta.color }}></i> {meta.title}
        <span className="badge b-amber" style={{ marginLeft: 8 }}>{groups.reduce((s, g) => s + g.items.length, 0)}</span>
      </div>
      <table className="tbl">
        <thead><tr><th>Patient</th><th>Details</th><th></th></tr></thead>
        <tbody>
          {groups.map((g) => (
            <tr key={g.visitId || g.patientId || g.patient?.id}>
              <td>
                <strong>{g.patient?.first_name} {g.patient?.last_name}</strong>
                <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{g.patient?.uhid}</span>
              </td>
              <td style={{ fontSize: 12 }}>
                <ItemsCell items={g.items} renderItem={renderItem} busyId={busyId} onDefer={onDefer} onDeny={onDeny} onReset={onReset} />
              </td>
              <td>
                <button className="btn btn-primary btn-sm" onClick={() => onBillNow(g)}>
                  <i className="ti ti-receipt"></i> Bill Now
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// Same IST-day comparison the rest of the app uses for "today" (see
// ist_date()/istDayBoundsUTC() server-side) -- en-CA gives a plain
// YYYY-MM-DD string, safe for direct equality comparison.
function istDateOnly(dateInput) {
  return new Date(dateInput).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function isToday(dateInput) {
  if (!dateInput) return false;
  return istDateOnly(dateInput) === istDateOnly(new Date());
}

// Filters each group's items down to today's only, dropping any group
// left with zero items -- a patient with one item from today and one
// from last week still shows, just with only the today item visible.
function filterGroupsToToday(groups) {
  return groups
    .map((g) => ({ ...g, items: g.items.filter((item) => isToday(item.created_at)) }))
    .filter((g) => g.items.length > 0);
}

export default function PendingBillingWidget({ onTotalChange, bare = false, todayOnly = false }) {
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

  const investigationsShown = todayOnly ? filterGroupsToToday(investigations) : investigations;
  const proceduresShown = todayOnly ? filterGroupsToToday(procedures) : procedures;
  const pharmacyShown = todayOnly ? filterGroupsToToday(pharmacy) : pharmacy;
  const biometryShown = todayOnly ? filterGroupsToToday(biometry) : biometry;

  const totalItems = investigationsShown.reduce((s, g) => s + g.items.length, 0)
    + proceduresShown.reduce((s, g) => s + g.items.length, 0)
    + pharmacyShown.reduce((s, g) => s + g.items.length, 0)
    + biometryShown.reduce((s, g) => s + g.items.length, 0);

  useEffect(() => {
    if (!loading && onTotalChange) onTotalChange(totalItems);
  }, [loading, totalItems, onTotalChange]);

  function billNowFor(type, group) {
    const ids = group.items.map((i) => i.id).join(',');
    router.push(`/billing/new?visitId=${group.visitId}&${CATEGORY_META[type].param}=${ids}`);
  }

  const listContent = (
    <>
      {!bare && (
        <>
          <div className="card-title" style={{ marginBottom: 4, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
            <span><i className="ti ti-clipboard-list" style={{ color: 'var(--red)' }}></i> Pending Billing</span>
            {totalItems > 0 && <span className="badge b-red">{totalItems}</span>}
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Everything prescribed or recommended for a patient, not yet billed -- by category.
          </div>
        </>
      )}

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && totalItems === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>
          {todayOnly && (investigations.length + procedures.length + pharmacy.length + biometry.length) > 0
            ? 'Nothing pending from today -- switch to Historical to see the older backlog.'
            : 'Nothing pending -- everything is billed.'}
        </div>
      )}

      {!loading && (
        <>
          <CategoryTable
            type="Investigation" groups={investigationsShown} busyId={busyId}
            onDefer={(id) => withBusy(id, (x) => markInvestigationDeferred(x, 'Patient asked to come back later'))}
            onDeny={(id) => withBusy(id, (x) => markInvestigationDenied(x, 'Patient declined at Front Office'))}
            onReset={(id) => withBusy(id, resetInvestigationBilling)}
            onBillNow={(g) => billNowFor('Investigation', g)}
            renderItem={(io) => <>{io.name} <span style={{ color: 'var(--g400)' }}>({io.eye})</span></>}
          />
          <CategoryTable
            type="Biometry" groups={biometryShown} busyId={busyId}
            onDefer={(id) => withBusy(id, (x) => markBiometryDeferred(x, 'Patient asked to come back later'))}
            onDeny={(id) => withBusy(id, (x) => markBiometryDenied(x, 'Patient declined at Front Office'))}
            onReset={(id) => withBusy(id, resetBiometryBilling)}
            onBillNow={(g) => billNowFor('Biometry', g)}
            renderItem={() => <>Biometry</>}
          />
          <CategoryTable
            type="Procedure" groups={proceduresShown} busyId={busyId}
            onBillNow={(g) => billNowFor('Procedure', g)}
            renderItem={(p) => <>{p.name} <span style={{ color: 'var(--g400)' }}>({p.eye})</span>{p.notes && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{p.notes}</div>}</>}
          />
          <CategoryTable
            type="Pharmacy" groups={pharmacyShown} busyId={busyId}
            onDefer={(id) => withBusy(id, (x) => markPrescriptionDeferred(x, 'Patient asked to come back later'))}
            onDeny={(id) => withBusy(id, (x) => markPrescriptionDenied(x, 'Patient declined at Front Office'))}
            onReset={(id) => withBusy(id, resetPrescriptionBilling)}
            onBillNow={(g) => billNowFor('Pharmacy', g)}
            renderItem={(rx) => <>{rx.drug_name} <span style={{ color: 'var(--g400)' }}>({rx.eye})</span></>}
          />
        </>
      )}
    </>
  );

  if (bare) return listContent;

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      {listContent}
    </div>
  );
}
