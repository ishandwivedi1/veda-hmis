'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getPharmacyWorkspace,
  billPharmacyItems,
  dispensePrescription,
  markPrescriptionDenied,
  markPrescriptionDeferred,
  resetPrescriptionBilling,
} from '../actions';

function fmt(n) {
  return `Rs ${Number(n || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
}

export default function Workspace({ visitId }) {
  const router = useRouter();
  const [visit, setVisit] = useState(null);
  const [items, setItems] = useState([]);
  const [drugCatalog, setDrugCatalog] = useState([]);
  const [selections, setSelections] = useState({}); // { [prescriptionId]: { drugId, qty } }
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [billing, setBilling] = useState(false);
  const [noteDraft, setNoteDraft] = useState({});

  const refresh = useCallback(async () => {
    const data = await getPharmacyWorkspace(visitId);
    setVisit(data.visit);
    setItems(data.items);
    setDrugCatalog(data.drugCatalog);
    // Default each unbilled item to its suggested catalog match and qty 1
    setSelections((prev) => {
      const next = { ...prev };
      data.items.forEach((rx) => {
        if (rx.billing_status !== 'Pending') return;
        if (!next[rx.id]) next[rx.id] = { drugId: rx.suggestedDrugId || '', qty: rx.qty || 1 };
      });
      return next;
    });
    setLoading(false);
  }, [visitId]);

  useEffect(() => { refresh(); }, [refresh]);

  // The payment tab closes itself after a successful receipt (see
  // collect-payment-tab.js) -- refreshing on focus means the moment
  // that happens and this tab regains attention, the just-billed item
  // already shows its updated status without a manual reload.
  useEffect(() => {
    window.addEventListener('focus', refresh);
    return () => window.removeEventListener('focus', refresh);
  }, [refresh]);

  function updateSelection(rxId, field, value) {
    setSelections((prev) => ({ ...prev, [rxId]: { ...prev[rxId], [field]: value } }));
  }

  const billableItems = items.filter((rx) => rx.billing_status === 'Pending');
  const [checked, setChecked] = useState({});
  useEffect(() => {
    // Check everything billable by default so a normal "bill all, send to payment" is one click
    const initial = {};
    billableItems.forEach((rx) => { initial[rx.id] = true; });
    setChecked((prev) => ({ ...initial, ...prev }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items.length]);

  function lineTotal(rx) {
    const sel = selections[rx.id];
    const drug = drugCatalog.find((d) => d.id === sel?.drugId);
    if (!drug || !sel?.qty) return null;
    const gross = drug.rate * sel.qty;
    const gst = Math.round((gross * drug.gst_pct / 100) * 100) / 100;
    return { gross, gst, net: Math.round((gross + gst) * 100) / 100, drug };
  }

  const grandTotal = billableItems
    .filter((rx) => checked[rx.id])
    .reduce((sum, rx) => sum + (lineTotal(rx)?.net || 0), 0);

  async function handleBillAndPay() {
    setError('');
    const selected = billableItems.filter((rx) => checked[rx.id]);
    if (selected.length === 0) { setError('Select at least one item to bill.'); return; }

    const payload = [];
    for (const rx of selected) {
      const t = lineTotal(rx);
      if (!t) { setError(`Pick a catalog match and quantity for ${rx.drug_name} before billing.`); return; }
      payload.push({
        prescriptionId: rx.id,
        drugName: rx.drug_name,
        serviceCode: t.drug.code,
        rate: t.drug.rate,
        gstPct: t.drug.gst_pct,
        qty: selections[rx.id].qty,
      });
    }

    setBilling(true);
    const result = await billPharmacyItems(visitId, payload);
    setBilling(false);
    if (result.error) { setError(result.error); return; }

    // Opens as a real new tab rather than navigating away from the
    // Workspace, since the pharmacist typically wants to keep working
    // through the queue -- the payment tab closes itself once the
    // receipt is confirmed there (see collect-payment-tab.js), which
    // naturally drops focus back here.
    const patientId = visit?.patients?.id;
    const url = `/payments/collect?patientId=${patientId}&invoiceId=${result.invoiceId}&popup=1`;
    window.open(url, '_blank');
    refresh();
  }

  async function handleDispense(rxId) {
    setError('');
    const result = await dispensePrescription(rxId);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAction(fn, rxId) {
    setError('');
    const result = await fn(rxId, noteDraft[rxId] || '');
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  if (loading) return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>Loading...</div>;
  if (!visit) return <div className="msg-err">Visit not found.</div>;

  const billed = items.filter((rx) => rx.billing_status !== 'Pending');

  return (
    <div style={{ maxWidth: 800, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/pharmacy')}>
        <i className="ti ti-arrow-left"></i> Back to Dashboard
      </button>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 16, fontWeight: 700 }}>{visit.patients?.first_name} {visit.patients?.last_name}</div>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>{visit.patients?.uhid} &middot; Visit {visit.visit_number} &middot; {visit.patients?.mobile}</div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {billableItems.length > 0 && (
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>Prescribed -- Not Yet Billed</div>
          {billableItems.map((rx) => {
            const t = lineTotal(rx);
            return (
              <div key={rx.id} style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
                <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
                  <input
                    type="checkbox"
                    checked={!!checked[rx.id]}
                    onChange={(e) => setChecked((prev) => ({ ...prev, [rx.id]: e.target.checked }))}
                    style={{ marginTop: 4 }}
                  />
                  <div style={{ flex: 1 }}>
                    <div style={{ fontWeight: 600, fontSize: 13 }}>{rx.drug_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g400)' }}>{rx.dosage} {rx.frequency} x {rx.duration} -- {rx.eye}</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '2fr 90px 1fr', gap: 8, marginTop: 8 }}>
                      <select
                        className="fi fi-sm"
                        value={selections[rx.id]?.drugId || ''}
                        onChange={(e) => updateSelection(rx.id, 'drugId', e.target.value)}
                      >
                        <option value="">-- Match catalog item --</option>
                        {drugCatalog.map((d) => (
                          <option key={d.id} value={d.id}>{d.brand ? `${d.brand} (${d.generic})` : d.generic} -- {fmt(d.rate)}</option>
                        ))}
                      </select>
                      <input
                        type="number"
                        className="fi fi-sm"
                        min="1"
                        value={selections[rx.id]?.qty || 1}
                        onChange={(e) => updateSelection(rx.id, 'qty', parseInt(e.target.value, 10) || 1)}
                      />
                      <div style={{ fontSize: 13, fontWeight: 700, alignSelf: 'center', textAlign: 'right' }}>
                        {t ? fmt(t.net) : '--'}
                      </div>
                    </div>
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6, marginTop: 8, marginLeft: 26 }}>
                  <input
                    type="text"
                    className="fi fi-sm"
                    placeholder="Note (why declined/deferred)"
                    style={{ maxWidth: 220, fontSize: 11 }}
                    value={noteDraft[rx.id] || ''}
                    onChange={(e) => setNoteDraft((prev) => ({ ...prev, [rx.id]: e.target.value }))}
                  />
                  <button className="btn" style={{ fontSize: 11, padding: '3px 9px' }} onClick={() => handleAction(markPrescriptionDenied, rx.id)}>
                    Declined / Bought Elsewhere
                  </button>
                  <button className="btn" style={{ fontSize: 11, padding: '3px 9px' }} onClick={() => handleAction(markPrescriptionDeferred, rx.id)}>
                    Deferred
                  </button>
                </div>
              </div>
            );
          })}

          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 14 }}>
            <div style={{ fontSize: 15, fontWeight: 800 }}>Total: {fmt(grandTotal)}</div>
            <button className="btn btn-primary" disabled={billing} onClick={handleBillAndPay}>
              {billing ? 'Billing...' : <><i className="ti ti-receipt"></i> Bill & Send to Payment</>}
            </button>
          </div>
        </div>
      )}

      {billed.length > 0 && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>Billed / Actioned</div>
          {billed.map((rx) => (
            <div key={rx.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
              <span>
                <strong>{rx.drug_name}</strong> &middot; Qty {rx.qty}
                {rx.billing_status === 'Billed' && <span className="badge b-green" style={{ marginLeft: 6, fontSize: 10 }}>Billed</span>}
                {rx.billing_status === 'Denied' && <span className="badge b-red" style={{ marginLeft: 6, fontSize: 10 }}>Declined</span>}
                {rx.billing_status === 'Deferred' && <span className="badge b-gray" style={{ marginLeft: 6, fontSize: 10 }}>Deferred</span>}
                {rx.status === 'Dispensed' && <span className="badge b-blue" style={{ marginLeft: 6, fontSize: 10 }}>Dispensed</span>}
              </span>
              <span style={{ display: 'flex', gap: 6 }}>
                {rx.status !== 'Dispensed' && (
                  <button className="btn" style={{ padding: '3px 10px', fontSize: 11 }} onClick={() => handleDispense(rx.id)}>Dispense</button>
                )}
                {(rx.billing_status === 'Denied' || rx.billing_status === 'Deferred') && (
                  <button className="btn" style={{ padding: '3px 10px', fontSize: 11 }} onClick={() => handleAction(resetPrescriptionBilling, rx.id)}>Undo</button>
                )}
              </span>
            </div>
          ))}
        </div>
      )}

      {items.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No prescriptions found for this visit.
        </div>
      )}
    </div>
  );
}
