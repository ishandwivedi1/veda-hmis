'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useRouter } from 'next/navigation';
import {
  getPharmacyWorkspace,
  billPharmacyItems,
  dispenseAllForVisit,
  markPrescriptionDenied,
  markPrescriptionDeferred,
  resetPrescriptionBilling,
} from '../actions';

function fmt(n) {
  return `Rs ${Number(n || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
}

const BILLING_BADGE = { Pending: 'b-amber', Billed: 'b-green', Denied: 'b-red', Deferred: 'b-gray' };

export default function Workspace({ visitId }) {
  const router = useRouter();
  const [visit, setVisit] = useState(null);
  const [items, setItems] = useState([]);
  const [drugCatalog, setDrugCatalog] = useState([]);
  const [selections, setSelections] = useState({}); // { [prescriptionId]: { drugId, qty, discType, discValue } }
  const [checked, setChecked] = useState({});
  const [showMatchPicker, setShowMatchPicker] = useState({}); // rows where the pharmacist asked to override a confident exact match
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [billing, setBilling] = useState(false);
  const [noteDraft, setNoteDraft] = useState({});
  const [expandedNoteId, setExpandedNoteId] = useState(null);

  const refresh = useCallback(async () => {
    const data = await getPharmacyWorkspace(visitId);
    setVisit(data.visit);
    setItems(data.items);
    setDrugCatalog(data.drugCatalog);
    setSelections((prev) => {
      const next = { ...prev };
      data.items.forEach((rx) => {
        if (rx.billing_status !== 'Pending') return;
        // suggestedQty is Pharmacy's computed default -- a single unit
        // for bottle/tube forms, or dosage x frequency x duration
        // (summed across every step for a tapering schedule) for
        // tablets/capsules. Always editable, never locked.
        if (!next[rx.id]) next[rx.id] = { drugId: rx.suggestedDrugId || '', qty: rx.suggestedQty ?? rx.qty ?? 1, discType: 'fixed', discValue: 0, manualRate: '', manualGstPct: '' };
      });
      return next;
    });
    setChecked((prev) => {
      const next = { ...prev };
      data.items.forEach((rx) => {
        if (rx.billing_status === 'Pending' && next[rx.id] === undefined) next[rx.id] = true;
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

  // Same math as billing/new/new-invoice-tab.js's computeLine() -- GST
  // computed on the post-discount amount, and a fixed-Rs discount is
  // capped at the line's gross so it can never make a line negative.
  // A prescribed drug not in the catalog (no drugId picked) can still
  // be billed off a manually entered rate/GST%, rather than forcing
  // the pharmacist to pick some other catalog drug as a stand-in.
  function lineTotal(rx) {
    if (rx.billing_status === 'Billed') {
      const li = rx.invoice_line_items;
      if (!li) return null;
      const gross = li.rate * li.qty;
      return { qty: li.qty, rate: li.rate, discPct: gross > 0 ? Math.round((li.disc / gross) * 10000) / 100 : 0, net: Number(li.net) };
    }
    const sel = selections[rx.id];
    if (!sel?.qty) return null;

    const drug = sel.drugId ? drugCatalog.find((d) => d.id === sel.drugId) : null;
    let rate, gstPct;
    if (drug) {
      rate = drug.rate; gstPct = drug.gst_pct;
    } else if (sel.manualRate !== '' && sel.manualRate != null) {
      rate = Number(sel.manualRate) || 0; gstPct = Number(sel.manualGstPct) || 0;
    } else {
      return null;
    }

    const gross = rate * sel.qty;
    let disc = 0;
    if (sel.discType === 'pct') disc = Math.round((gross * Math.min(100, Math.max(0, sel.discValue || 0)) / 100) * 100) / 100;
    else if (sel.discType === 'fixed') disc = Math.min(Math.max(0, sel.discValue || 0), gross);
    const taxable = gross - disc;
    const gst = Math.round((taxable * gstPct / 100) * 100) / 100;
    return { qty: sel.qty, rate, gstPct, disc, net: Math.round((taxable + gst) * 100) / 100, drug };
  }

  const grandTotal = items.reduce((sum, rx) => {
    if (rx.billing_status === 'Denied' || rx.billing_status === 'Deferred') return sum;
    if (rx.billing_status === 'Pending' && !checked[rx.id]) return sum;
    return sum + (lineTotal(rx)?.net || 0);
  }, 0);

  async function handleBillAndPay() {
    setError('');
    const selected = items.filter((rx) => rx.billing_status === 'Pending' && checked[rx.id]);
    if (selected.length === 0) { setError('Select at least one item to bill.'); return; }

    const payload = [];
    for (const rx of selected) {
      const t = lineTotal(rx);
      if (!t) { setError(`Pick a catalog match, or enter a manual price, and a quantity for ${rx.drug_name} before billing.`); return; }
      payload.push({
        prescriptionIds: rx.stepIds,
        drugName: rx.drug_name,
        serviceCode: t.drug?.code || null,
        rate: t.rate,
        gstPct: t.gstPct,
        qty: selections[rx.id].qty,
        discType: selections[rx.id].discType || 'pct',
        discValue: selections[rx.id].discValue || 0,
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

  async function handleDispense(rx) {
    setError('');
    // A tapering schedule's steps dispense together in one action --
    // stepIds is a single-element array for a non-taper item, so this
    // works identically either way.
    const result = await dispenseAllForVisit(rx.stepIds);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAction(fn, rx) {
    setError('');
    // rx.id is a taper_group_id (not a real prescriptions.id) for a
    // grouped tapering schedule -- act on every underlying step.
    const result = await fn(rx.stepIds, noteDraft[rx.id] || '');
    if (result.error) { setError(result.error); return; }
    setExpandedNoteId(null);
    refresh();
  }

  if (loading) return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>Loading...</div>;
  if (!visit) return <div className="msg-err">Visit not found.</div>;

  const anyBillable = items.some((rx) => rx.billing_status === 'Pending');

  return (
    <div style={{ maxWidth: 1180, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/pharmacy')}>
        <i className="ti ti-arrow-left"></i> Back to Dashboard
      </button>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <div style={{ fontSize: 16, fontWeight: 700 }}>{formatPatientName(visit.patients)}</div>
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>{visit.patients?.uhid} &middot; Visit {visit.visit_number} &middot; {visit.patients?.mobile}</div>
          </div>
          {items.length > 0 && (
            <button className="btn btn-sm" onClick={() => window.open(`/prescription-print/${visitId}`, '_blank')}>
              <i className="ti ti-printer"></i> Print Prescription
            </button>
          )}
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {items.length > 0 && (
        <div className="card" style={{ marginBottom: 16 }}>
          <table className="tbl">
            <thead>
              <tr>
                <th style={{ width: 26 }}></th>
                <th style={{ width: 34 }}>S.No</th>
                <th>Medicine</th>
                <th style={{ width: 60 }}>Qty</th>
                <th style={{ width: 90 }}>Rate</th>
                <th style={{ width: 130 }}>Discount</th>
                <th style={{ width: 100 }}>Billing Status</th>
                <th style={{ width: 110 }}>Dispensing Status</th>
                <th style={{ textAlign: 'right', width: 90 }}>Total</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {items.map((rx, i) => {
                const t = lineTotal(rx);
                const isPending = rx.billing_status === 'Pending';
                const isActioned = rx.billing_status === 'Denied' || rx.billing_status === 'Deferred';
                return (
                  <Fragment key={rx.id}>
                    <tr>
                      <td>
                        {isPending && (
                          <input
                            type="checkbox"
                            checked={!!checked[rx.id]}
                            onChange={(e) => setChecked((prev) => ({ ...prev, [rx.id]: e.target.checked }))}
                          />
                        )}
                      </td>
                      <td>{i + 1}</td>
                      <td>
                        <div style={{ fontWeight: 600, fontSize: 13 }}>
                          {rx.drug_name}
                          {rx.isTaper && (
                            <span style={{ marginLeft: 8, fontSize: 10, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}>
                              <i className="ti ti-chart-line"></i> Tapering
                            </span>
                          )}
                        </div>
                        {rx.isTaper ? (
                          // Dosage, frequency, and duration can all differ
                          // per step now -- a joined string ("2 tablets ->
                          // 1 tablet" separate from "BD x1wk -> OD x1wk")
                          // leaves the pharmacist guessing which dosage
                          // pairs with which frequency. A real table
                          // removes the ambiguity entirely.
                          <div style={{ marginTop: 5, marginBottom: 4, border: '1px solid var(--purple)', borderRadius: 6, overflow: 'hidden' }}>
                            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 11.5 }}>
                              <thead>
                                <tr style={{ background: 'var(--purple-lt)' }}>
                                  <th style={{ padding: '4px 8px', textAlign: 'left', fontWeight: 700, width: 24, color: 'var(--purple)' }}>#</th>
                                  <th style={{ padding: '4px 8px', textAlign: 'left', fontWeight: 700, color: 'var(--purple)' }}>Dosage</th>
                                  <th style={{ padding: '4px 8px', textAlign: 'left', fontWeight: 700, color: 'var(--purple)' }}>Frequency</th>
                                  <th style={{ padding: '4px 8px', textAlign: 'left', fontWeight: 700, color: 'var(--purple)' }}>Duration</th>
                                </tr>
                              </thead>
                              <tbody>
                                {rx.steps.map((s) => (
                                  <tr key={s.step} style={{ borderTop: '1px solid var(--g100)' }}>
                                    <td style={{ padding: '4px 8px', color: 'var(--g500)' }}>{s.step}</td>
                                    <td style={{ padding: '4px 8px', fontWeight: 600 }}>{s.dosage}</td>
                                    <td style={{ padding: '4px 8px' }}>{s.frequency}</td>
                                    <td style={{ padding: '4px 8px' }}>{s.duration}</td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                            <div style={{ padding: '4px 8px', fontSize: 10.5, color: 'var(--g500)', background: 'var(--g50)', borderTop: '1px solid var(--g100)' }}>
                              Eye: {rx.eye} &middot; then stop
                            </div>
                          </div>
                        ) : (
                          <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                            {rx.eye} &middot; {rx.dosage} &middot; {rx.plainFrequency}{rx.duration ? ` \u00b7 for ${rx.duration}` : ''}
                          </div>
                        )}
                        {isPending && rx.qtyComputed && (
                          <div style={{ fontSize: 10.5, color: 'var(--green)', marginTop: 2 }}>
                            <i className="ti ti-calculator"></i> Quantity computed from the {rx.isTaper ? 'full schedule' : 'dosage/frequency/duration'} -- verify before billing.
                          </div>
                        )}
                        {isPending && rx.needsManualQty && (
                          <div style={{ fontSize: 10.5, color: 'var(--amber)', marginTop: 2 }}>
                            <i className="ti ti-alert-triangle"></i> {rx.taperNote}
                          </div>
                        )}
                        {isPending && (() => {
                          const isConfident = rx.isExactMatch && selections[rx.id]?.drugId === rx.suggestedDrugId;
                          if (isConfident && !showMatchPicker[rx.id]) {
                            const matched = drugCatalog.find((d) => d.id === rx.suggestedDrugId);
                            return (
                              <div style={{ marginTop: 4, fontSize: 11.5 }}>
                                <i className="ti ti-check" style={{ color: 'var(--green)' }}></i>{' '}
                                {matched ? (matched.brand ? `${matched.brand} (${matched.generic})` : matched.generic) : ''} -- {matched ? fmt(matched.rate) : ''}
                                <button className="btn" style={{ padding: '0 6px', fontSize: 10, marginLeft: 6 }} onClick={() => setShowMatchPicker((p) => ({ ...p, [rx.id]: true }))}>Change</button>
                              </div>
                            );
                          }
                          return (
                            <>
                              <select
                                className="fi fi-sm"
                                style={{ marginTop: 4, maxWidth: 260 }}
                                value={selections[rx.id]?.drugId || ''}
                                onChange={(e) => updateSelection(rx.id, 'drugId', e.target.value)}
                              >
                                <option value="">-- Match catalog item --</option>
                                {drugCatalog.map((d) => (
                                  <option key={d.id} value={d.id}>{d.brand ? `${d.brand} (${d.generic})` : d.generic} -- {fmt(d.rate)}</option>
                                ))}
                              </select>
                              {!selections[rx.id]?.drugId && (
                                <div style={{ marginTop: 4 }}>
                                  <div style={{ fontSize: 10.5, color: 'var(--amber)', marginBottom: 2 }}>
                                    <i className="ti ti-alert-triangle"></i> Not in the drug catalog -- enter a price manually.
                                  </div>
                                  <div style={{ display: 'flex', gap: 4 }}>
                                    <input
                                      type="number" min="0" step="0.01" className="fi fi-sm" style={{ width: 80 }}
                                      placeholder="Rate Rs."
                                      value={selections[rx.id]?.manualRate ?? ''}
                                      onChange={(e) => updateSelection(rx.id, 'manualRate', e.target.value)}
                                    />
                                    <input
                                      type="number" min="0" max="100" step="0.01" className="fi fi-sm" style={{ width: 60 }}
                                      placeholder="GST %"
                                      value={selections[rx.id]?.manualGstPct ?? ''}
                                      onChange={(e) => updateSelection(rx.id, 'manualGstPct', e.target.value)}
                                    />
                                  </div>
                                </div>
                              )}
                            </>
                          );
                        })()}
                      </td>
                      <td>
                        {isPending ? (
                          <input
                            type="number" min="1" className="fi fi-sm" style={{ width: 55 }}
                            value={selections[rx.id]?.qty || 1}
                            onChange={(e) => updateSelection(rx.id, 'qty', parseInt(e.target.value, 10) || 1)}
                          />
                        ) : (t?.qty ?? '--')}
                      </td>
                      <td>{t?.rate != null ? fmt(t.rate) : '--'}</td>
                      <td>
                        {isPending ? (
                          <div style={{ display: 'flex', gap: 3 }}>
                            <select
                              className="fi fi-sm" style={{ width: 52, padding: '4px 2px' }}
                              value={selections[rx.id]?.discType || 'fixed'}
                              onChange={(e) => updateSelection(rx.id, 'discType', e.target.value)}
                            >
                              <option value="fixed">Rs.</option>
                              <option value="pct">%</option>
                            </select>
                            <input
                              type="number" min="0" className="fi fi-sm" style={{ width: 60 }}
                              placeholder={selections[rx.id]?.discType === 'fixed' ? 'Rs.' : '%'}
                              value={selections[rx.id]?.discValue || ''}
                              onChange={(e) => updateSelection(rx.id, 'discValue', parseFloat(e.target.value) || 0)}
                            />
                          </div>
                        ) : (t?.discPct > 0 ? `${t.discPct}%` : '--')}
                      </td>
                      <td><span className={`badge ${BILLING_BADGE[rx.billing_status] || 'b-gray'}`} style={{ fontSize: 10 }}>{rx.billing_status}</span></td>
                      <td>
                        {rx.status === 'Dispensed'
                          ? <span className="badge b-blue" style={{ fontSize: 10 }}>Dispensed</span>
                          : <span className="badge b-gray" style={{ fontSize: 10 }}>Not Dispensed</span>}
                      </td>
                      <td style={{ textAlign: 'right', fontWeight: 700 }}>{t ? fmt(t.net) : '--'}</td>
                      <td style={{ whiteSpace: 'nowrap' }}>
                        {isPending && (
                          <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} onClick={() => setExpandedNoteId(expandedNoteId === rx.id ? null : rx.id)}>
                            Decline / Defer
                          </button>
                        )}
                        {rx.billing_status === 'Billed' && rx.status !== 'Dispensed' && (
                          <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} onClick={() => handleDispense(rx)}>Dispense</button>
                        )}
                        {isActioned && (
                          <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} onClick={() => handleAction(resetPrescriptionBilling, rx)}>Undo</button>
                        )}
                      </td>
                    </tr>
                    {expandedNoteId === rx.id && (
                      <tr>
                        <td colSpan={10} style={{ background: 'var(--g50)', padding: 8 }}>
                          <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                            <input
                              type="text" className="fi fi-sm" placeholder="Note (optional)" style={{ maxWidth: 240 }}
                              value={noteDraft[rx.id] || ''}
                              onChange={(e) => setNoteDraft((prev) => ({ ...prev, [rx.id]: e.target.value }))}
                            />
                            <button className="btn" style={{ fontSize: 11, padding: '3px 9px' }} onClick={() => handleAction(markPrescriptionDenied, rx)}>
                              Declined / Bought Elsewhere
                            </button>
                            <button className="btn" style={{ fontSize: 11, padding: '3px 9px' }} onClick={() => handleAction(markPrescriptionDeferred, rx)}>
                              Deferred
                            </button>
                          </div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={8} style={{ textAlign: 'right', fontWeight: 800, fontSize: 14 }}>Total</td>
                <td style={{ textAlign: 'right', fontWeight: 800, fontSize: 14 }}>{fmt(grandTotal)}</td>
                <td></td>
              </tr>
            </tfoot>
          </table>

          {anyBillable && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 14 }}>
              <button className="btn btn-primary" disabled={billing} onClick={handleBillAndPay}>
                {billing ? 'Billing...' : <><i className="ti ti-receipt"></i> Bill Selected & Send to Payment</>}
              </button>
            </div>
          )}
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
