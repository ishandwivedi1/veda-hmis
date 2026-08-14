'use client';

import { useState, useEffect, useCallback } from 'react';
import InventoryTabs from '../inventory-tabs';
import DownloadPdfButton from '@/app/components/DownloadPdfButton';
import { getStockValuationReport, getExpiryReport, getConsumptionReport, getVendorPurchaseSummary } from '../actions';

function daysAgo(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return d.toISOString().slice(0, 10);
}
const today = () => new Date().toISOString().slice(0, 10);

export default function InventoryReportsPage() {
  const [valuation, setValuation] = useState({ rows: [], totalValue: 0 });
  const [expiryDays, setExpiryDays] = useState('90');
  const [expiry, setExpiry] = useState([]);
  const [consumptionStart, setConsumptionStart] = useState(() => daysAgo(30));
  const [consumptionEnd, setConsumptionEnd] = useState(() => today());
  const [consumption, setConsumption] = useState([]);
  const [vendorStart, setVendorStart] = useState(() => daysAgo(90));
  const [vendorEnd, setVendorEnd] = useState(() => today());
  const [vendorSummary, setVendorSummary] = useState([]);
  const [loading, setLoading] = useState(true);

  const loadValuation = useCallback(async () => setValuation(await getStockValuationReport()), []);
  const loadExpiry = useCallback(async () => setExpiry(await getExpiryReport(expiryDays)), [expiryDays]);
  const loadConsumption = useCallback(async () => setConsumption(await getConsumptionReport(consumptionStart, consumptionEnd)), [consumptionStart, consumptionEnd]);
  const loadVendorSummary = useCallback(async () => setVendorSummary(await getVendorPurchaseSummary(vendorStart, vendorEnd)), [vendorStart, vendorEnd]);

  useEffect(() => {
    Promise.all([loadValuation(), loadExpiry(), loadConsumption(), loadVendorSummary()]).then(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => { loadExpiry(); }, [loadExpiry]);
  useEffect(() => { loadConsumption(); }, [loadConsumption]);
  useEffect(() => { loadVendorSummary(); }, [loadVendorSummary]);

  return (
    <div>
      <div className="no-print"><InventoryTabs /></div>
      <div className="no-print" style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 12 }}>
        <DownloadPdfButton label="Download All Reports as PDF" />
      </div>

      {loading ? (
        <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading reports...</div>
      ) : (
        <>
          {/* STOCK VALUATION */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> Stock Valuation</div>
              <div style={{ fontSize: 13 }}>
                <span style={{ color: 'var(--g500)' }}>Total value on shelf: </span>
                <span style={{ fontWeight: 800, fontSize: 16 }}>Rs.{valuation.totalValue.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</span>
              </div>
            </div>
            <table className="tbl">
              <thead><tr><th>Drug</th><th>In Stock</th><th>Avg. Cost</th><th>Value</th></tr></thead>
              <tbody>
                {valuation.rows.map((r) => (
                  <tr key={r.name}>
                    <td style={{ fontWeight: 600 }}>{r.name}</td>
                    <td>{r.qty} {r.unit}</td>
                    <td>Rs.{r.avgCost.toFixed(2)}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{r.value.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</td>
                  </tr>
                ))}
                {valuation.rows.length === 0 && (
                  <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No stock on hand yet.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          {/* EXPIRY REPORT */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}>
                <i className="ti ti-calendar-exclamation" style={{ color: 'var(--red)' }}></i> Expiry Report
                <span className="print-only" style={{ fontWeight: 400, fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>(next {expiryDays} days)</span>
              </div>
              <select className="fi fi-sm no-print" style={{ width: 160 }} value={expiryDays} onChange={(e) => setExpiryDays(e.target.value)}>
                <option value="30">Next 30 days</option>
                <option value="60">Next 60 days</option>
                <option value="90">Next 90 days</option>
                <option value="180">Next 180 days</option>
              </select>
            </div>
            <table className="tbl">
              <thead><tr><th>Drug</th><th>Batch</th><th>Expiry Date</th><th>Days Left</th><th>Qty</th></tr></thead>
              <tbody>
                {expiry.map((e) => (
                  <tr key={e.batchNumber + e.expiryDate + e.name}>
                    <td style={{ fontWeight: 600 }}>{e.name}</td>
                    <td>{e.batchNumber || '--'}</td>
                    <td>{new Date(e.expiryDate).toLocaleDateString('en-IN')}</td>
                    <td style={{ color: e.daysLeft <= 30 ? 'var(--red)' : e.daysLeft <= 60 ? 'var(--amber)' : 'inherit', fontWeight: 600 }}>{e.daysLeft} days</td>
                    <td>{e.qty} {e.unit}</td>
                  </tr>
                ))}
                {expiry.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Nothing expiring in this window.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          {/* CONSUMPTION REPORT */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
              <div className="card-title" style={{ marginBottom: 0 }}>
                <i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Consumption Report
                <span className="print-only" style={{ fontWeight: 400, fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>({new Date(consumptionStart).toLocaleDateString('en-IN')} to {new Date(consumptionEnd).toLocaleDateString('en-IN')})</span>
              </div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input className="fi fi-sm no-print" type="date" value={consumptionStart} onChange={(e) => setConsumptionStart(e.target.value)} />
                <span style={{ fontSize: 12, color: 'var(--g400)' }}>to</span>
                <input className="fi fi-sm no-print" type="date" value={consumptionEnd} onChange={(e) => setConsumptionEnd(e.target.value)} />
              </div>
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>What actually moved off the shelf -- the real signal for how much to reorder.</div>
            <table className="tbl">
              <thead><tr><th>Drug</th><th>Consumed</th></tr></thead>
              <tbody>
                {consumption.map((c) => (
                  <tr key={c.name}>
                    <td style={{ fontWeight: 600 }}>{c.name}</td>
                    <td style={{ fontWeight: 600 }}>{c.consumed} {c.unit}</td>
                  </tr>
                ))}
                {consumption.length === 0 && (
                  <tr><td colSpan={2} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No dispensing recorded in this range.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          {/* VENDOR PURCHASE SUMMARY */}
          <div className="card">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
              <div className="card-title" style={{ marginBottom: 0 }}>
                <i className="ti ti-building-store" style={{ color: 'var(--purple)' }}></i> Vendor Purchase Summary
                <span className="print-only" style={{ fontWeight: 400, fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>({new Date(vendorStart).toLocaleDateString('en-IN')} to {new Date(vendorEnd).toLocaleDateString('en-IN')})</span>
              </div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input className="fi fi-sm no-print" type="date" value={vendorStart} onChange={(e) => setVendorStart(e.target.value)} />
                <span style={{ fontSize: 12, color: 'var(--g400)' }}>to</span>
                <input className="fi fi-sm no-print" type="date" value={vendorEnd} onChange={(e) => setVendorEnd(e.target.value)} />
              </div>
            </div>
            <table className="tbl">
              <thead><tr><th>Vendor</th><th>Bills</th><th>Total</th><th>Paid</th><th>Unpaid</th></tr></thead>
              <tbody>
                {vendorSummary.map((v) => (
                  <tr key={v.name}>
                    <td style={{ fontWeight: 600 }}>{v.name}</td>
                    <td>{v.bills}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{v.total.toLocaleString('en-IN')}</td>
                    <td style={{ color: 'var(--green)' }}>Rs.{v.paid.toLocaleString('en-IN')}</td>
                    <td style={{ color: v.unpaid > 0 ? 'var(--red)' : 'inherit', fontWeight: v.unpaid > 0 ? 600 : 400 }}>Rs.{v.unpaid.toLocaleString('en-IN')}</td>
                  </tr>
                ))}
                {vendorSummary.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No purchases in this range.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
