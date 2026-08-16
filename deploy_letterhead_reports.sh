#!/bin/bash
set -e

echo "=================================================="
echo "Deploying: Proper letterhead PDF reports"
echo "=================================================="
echo ""
echo "This script overwrites/creates the files itself -- no manual"
echo "upload or copy-paste needed -- then commits and pushes."
echo ""
echo "This also removes app/components/DownloadPdfButton.js, which is"
echo "no longer used now that every report links to a real letterhead"
echo "PDF route instead of a raw browser print of the on-screen view."
echo ""

rm -f "app/components/DownloadPdfButton.js"
mkdir -p "app/inventory-report-print/[type]"
mkdir -p "app/investigation-report-print"
mkdir -p "app/optometry-report-print"
mkdir -p "app/payments-report-print"
mkdir -p "app/reports-print"

cat > "app/(main)/inventory/reports/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState, useEffect, useCallback } from 'react';
import Link from 'next/link';
import InventoryTabs from '../inventory-tabs';
import { getStockValuationReport, getExpiryReport, getConsumptionReport, getVendorPurchaseSummary } from '../actions';

function daysAgo(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return d.toISOString().slice(0, 10);
}
const today = () => new Date().toISOString().slice(0, 10);

function PdfLink({ href }) {
  return (
    <Link href={href} target="_blank" className="btn btn-sm" style={{ textDecoration: 'none' }}>
      <i className="ti ti-file-download"></i> Download PDF
    </Link>
  );
}

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

      {loading ? (
        <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading reports...</div>
      ) : (
        <>
          {/* STOCK VALUATION */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> Stock Valuation</div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ fontSize: 13 }}>
                  <span style={{ color: 'var(--g500)' }}>Total value on shelf: </span>
                  <span style={{ fontWeight: 800, fontSize: 16 }}>Rs.{valuation.totalValue.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</span>
                </div>
                <PdfLink href="/inventory-report-print/valuation" />
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
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <select className="fi fi-sm" style={{ width: 160 }} value={expiryDays} onChange={(e) => setExpiryDays(e.target.value)}>
                  <option value="30">Next 30 days</option>
                  <option value="60">Next 60 days</option>
                  <option value="90">Next 90 days</option>
                  <option value="180">Next 180 days</option>
                </select>
                <PdfLink href={`/inventory-report-print/expiry?days=${expiryDays}`} />
              </div>
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
              </div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input className="fi fi-sm" type="date" value={consumptionStart} onChange={(e) => setConsumptionStart(e.target.value)} />
                <span style={{ fontSize: 12, color: 'var(--g400)' }}>to</span>
                <input className="fi fi-sm" type="date" value={consumptionEnd} onChange={(e) => setConsumptionEnd(e.target.value)} />
                <PdfLink href={`/inventory-report-print/consumption?from=${consumptionStart}&to=${consumptionEnd}`} />
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
              </div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input className="fi fi-sm" type="date" value={vendorStart} onChange={(e) => setVendorStart(e.target.value)} />
                <span style={{ fontSize: 12, color: 'var(--g400)' }}>to</span>
                <input className="fi fi-sm" type="date" value={vendorEnd} onChange={(e) => setVendorEnd(e.target.value)} />
                <PdfLink href={`/inventory-report-print/vendor?from=${vendorStart}&to=${vendorEnd}`} />
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
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/investigation/reports/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState } from 'react';
import Link from 'next/link';
import { getInvestigationReport } from '../actions';
import InvestigationTabs from '../investigation-tabs';

const RPT_DEFS = [
  { id: 'register', icon: 'ti-calendar', color: '--teal', title: 'Daily Investigation Register', desc: 'All investigations in period' },
  { id: 'type_summary', icon: 'ti-flask', color: '--blue', title: 'Investigation Type Summary', desc: 'Counts by investigation type' },
  { id: 'pending', icon: 'ti-clock', color: '--amber', title: 'Pending Investigations', desc: 'Not yet completed' },
  { id: 'quality', icon: 'ti-shield', color: '--green', title: 'Quality Report', desc: 'Unable to perform, with reasons' },
];

function toISODate(d) { return d.toISOString().slice(0, 10); }

const PRESETS = [
  { label: 'Today', range: () => { const t = toISODate(new Date()); return [t, t]; } },
  { label: 'This Week', range: () => { const now = new Date(); const from = new Date(now); from.setDate(now.getDate() - 6); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Month', range: () => { const now = new Date(); const from = new Date(now.getFullYear(), now.getMonth(), 1); return [toISODate(from), toISODate(now)]; } },
];

export default function InvestigationReportsPage() {
  const today = toISODate(new Date());
  const [fromDate, setFromDate] = useState(today);
  const [toDate, setToDate] = useState(today);
  const [report, setReport] = useState(null);
  const [activeReportId, setActiveReportId] = useState(null);
  const [loading, setLoading] = useState(null);

  function applyPreset(preset) {
    const [from, to] = preset.range();
    setFromDate(from);
    setToDate(to);
    if (activeReportId) openReport(activeReportId, from, to);
  }

  async function openReport(id, from, to) {
    setActiveReportId(id);
    setLoading(id);
    const data = await getInvestigationReport(id, from || fromDate, to || toDate);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <div className="no-print"><InvestigationTabs /></div>

      <div className="card no-print" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>Period</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          <span style={{ color: 'var(--g400)' }}>to</span>
          <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          {activeReportId && (
            <button className="btn btn-primary btn-sm" onClick={() => openReport(activeReportId)}>Apply</button>
          )}
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginLeft: 8 }}>
            {PRESETS.map((p) => (
              <button key={p.label} className="btn btn-sm" onClick={() => applyPreset(p)}>{p.label}</button>
            ))}
          </div>
        </div>
      </div>

      <div className="no-print" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 16 }}>
        {RPT_DEFS.map((r) => (
          <div
            key={r.id}
            onClick={() => openReport(r.id)}
            className="card"
            style={{ cursor: 'pointer', borderTop: `3px solid var(${r.color})`, background: activeReportId === r.id ? 'var(--g50)' : '#fff' }}
          >
            <i className={`ti ${r.icon}`} style={{ color: `var(${r.color})`, fontSize: 20 }}></i>
            <div style={{ fontWeight: 700, fontSize: 13, marginTop: 8 }}>{loading === r.id ? 'Loading...' : r.title}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{r.desc}</div>
          </div>
        ))}
      </div>

      {report && (
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-file"></i> {report.title}
            </div>
            <div className="no-print" style={{ display: 'flex', gap: 8 }}>
              <Link href={`/investigation-report-print?reportId=${activeReportId}&from=${fromDate}&to=${toDate}`} target="_blank" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-file-download"></i> Download PDF
              </Link>
              <button className="btn btn-sm" onClick={() => { setReport(null); setActiveReportId(null); }}><i className="ti ti-x"></i> Close</button>
            </div>
          </div>
          <table className="tbl">
            <thead><tr>{report.headers.map((h) => <th key={h}>{h}</th>)}</tr></thead>
            <tbody>
              {report.rows.map((row, i) => (
                <tr key={i}>{row.cols.map((c, j) => <td key={j}>{c}</td>)}</tr>
              ))}
              {report.rows.length === 0 && (
                <tr><td colSpan={report.headers.length} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No data for this period.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/optometry-reports/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState } from 'react';
import Link from 'next/link';
import { getOptometryReport } from './actions';

const RPT_DEFS = [
  { id: 'register', icon: 'ti-chart-bar', color: '--teal', title: 'Daily Assessment Register', desc: 'All assessments in period' },
  { id: 'va_distribution', icon: 'ti-eye', color: '--blue', title: 'VA Distribution', desc: 'Visual acuity across patients' },
  { id: 'iop_surveillance', icon: 'ti-activity', color: '--amber', title: 'IOP Surveillance', desc: 'Elevated IOP alerts and trends' },
];

function toISODate(d) {
  return d.toISOString().slice(0, 10);
}

const PRESETS = [
  { label: 'Today', range: () => { const t = toISODate(new Date()); return [t, t]; } },
  { label: 'This Week', range: () => { const now = new Date(); const from = new Date(now); from.setDate(now.getDate() - 6); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Month', range: () => { const now = new Date(); const from = new Date(now.getFullYear(), now.getMonth(), 1); return [toISODate(from), toISODate(now)]; } },
];

export default function OptometryReportsPage() {
  const today = toISODate(new Date());
  const [fromDate, setFromDate] = useState(today);
  const [toDate, setToDate] = useState(today);
  const [report, setReport] = useState(null);
  const [activeReportId, setActiveReportId] = useState(null);
  const [loading, setLoading] = useState(null);

  function applyPreset(preset) {
    const [from, to] = preset.range();
    setFromDate(from);
    setToDate(to);
    if (activeReportId) openReport(activeReportId, from, to);
  }

  async function openReport(id, from, to) {
    setActiveReportId(id);
    setLoading(id);
    const data = await getOptometryReport(id, from || fromDate, to || toDate);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <div className="card no-print" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>Period</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          <span style={{ color: 'var(--g400)' }}>to</span>
          <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          {activeReportId && (
            <button className="btn btn-primary btn-sm" onClick={() => openReport(activeReportId)}>Apply</button>
          )}
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginLeft: 8 }}>
            {PRESETS.map((p) => (
              <button key={p.label} className="btn btn-sm" onClick={() => applyPreset(p)}>{p.label}</button>
            ))}
          </div>
        </div>
      </div>

      <div className="no-print" style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14, marginBottom: 16 }}>
        {RPT_DEFS.map((r) => (
          <div
            key={r.id}
            onClick={() => openReport(r.id)}
            className="card"
            style={{ cursor: 'pointer', borderTop: `3px solid var(${r.color})`, background: activeReportId === r.id ? 'var(--g50)' : '#fff' }}
          >
            <i className={`ti ${r.icon}`} style={{ color: `var(${r.color})`, fontSize: 20 }}></i>
            <div style={{ fontWeight: 700, fontSize: 13, marginTop: 8 }}>{loading === r.id ? 'Loading...' : r.title}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{r.desc}</div>
          </div>
        ))}
      </div>

      {report && (
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-file"></i> {report.title}
            </div>
            <div className="no-print" style={{ display: 'flex', gap: 8 }}>
              <Link href={`/optometry-report-print?reportId=${activeReportId}&from=${fromDate}&to=${toDate}`} target="_blank" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-file-download"></i> Download PDF
              </Link>
              <button className="btn btn-sm" onClick={() => { setReport(null); setActiveReportId(null); }}><i className="ti ti-x"></i> Close</button>
            </div>
          </div>
          <table className="tbl">
            <thead><tr>{report.headers.map((h) => <th key={h}>{h}</th>)}</tr></thead>
            <tbody>
              {report.rows.map((row, i) => (
                <tr key={i}>{row.cols.map((c, j) => <td key={j}>{c}</td>)}</tr>
              ))}
              {report.rows.length === 0 && (
                <tr><td colSpan={report.headers.length} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No data for this period.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/payments/reports/payment-reports-tab.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState } from 'react';
import Link from 'next/link';
import { getPaymentReport } from '../actions';

const RPT_DEFS = [
  { id: 'daily', icon: 'ti-calendar', color: '--green', title: 'Collection', desc: 'All payments in period' },
  { id: 'mode', icon: 'ti-credit-card', color: '--blue', title: 'Payment Mode Summary', desc: 'Cash vs UPI vs Card' },
  { id: 'cash', icon: 'ti-cash', color: '--amber', title: 'Cash Collection', desc: 'Cash receipts' },
  { id: 'upi', icon: 'ti-device-mobile', color: '--teal', title: 'UPI Collection', desc: 'UPI transactions' },
  { id: 'advance', icon: 'ti-wallet', color: '--purple', title: 'Advance Report', desc: 'Advances and adjustments' },
  { id: 'out', icon: 'ti-clock', color: '--red', title: 'Outstanding Balances', desc: 'Pending invoice dues' },
  { id: 'register', icon: 'ti-receipt', color: '--green', title: 'Receipt Register', desc: 'All receipts' },
  { id: 'cancel', icon: 'ti-x-circle', color: '--red', title: 'Refund Report', desc: 'Refunds processed' },
];

function toISODate(d) {
  return d.toISOString().slice(0, 10);
}

// India's fiscal year runs April to March.
function fiscalYearRange(offsetYears = 0) {
  const now = new Date();
  let fyStartYear = now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1; // April = month index 3
  fyStartYear += offsetYears;
  const from = new Date(fyStartYear, 3, 1);
  const to = new Date(fyStartYear + 1, 2, 31);
  return [toISODate(from), toISODate(to)];
}

function fiscalQuarterRange() {
  const now = new Date();
  const month = now.getMonth(); // 0-11
  // FY quarters: Q1 Apr-Jun, Q2 Jul-Sep, Q3 Oct-Dec, Q4 Jan-Mar
  let qStartMonth, year = now.getFullYear();
  if (month >= 3 && month <= 5) qStartMonth = 3;
  else if (month >= 6 && month <= 8) qStartMonth = 6;
  else if (month >= 9 && month <= 11) qStartMonth = 9;
  else { qStartMonth = 0; }
  const from = new Date(year, qStartMonth, 1);
  const to = new Date(year, qStartMonth + 3, 0);
  return [toISODate(from), toISODate(to)];
}

const PRESETS = [
  { label: 'Today', range: () => { const t = toISODate(new Date()); return [t, t]; } },
  { label: 'This Week', range: () => { const now = new Date(); const from = new Date(now); from.setDate(now.getDate() - 6); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Month', range: () => { const now = new Date(); const from = new Date(now.getFullYear(), now.getMonth(), 1); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Quarter', range: fiscalQuarterRange },
  { label: 'This FY', range: () => fiscalYearRange(0) },
  { label: 'Last FY', range: () => fiscalYearRange(-1) },
];

export default function PaymentReportsTab() {
  const today = toISODate(new Date());
  const [fromDate, setFromDate] = useState(today);
  const [toDate, setToDate] = useState(today);
  const [report, setReport] = useState(null);
  const [activeReportId, setActiveReportId] = useState(null);
  const [loading, setLoading] = useState(null);

  function applyPreset(preset) {
    const [from, to] = preset.range();
    setFromDate(from);
    setToDate(to);
    if (activeReportId) openReport(activeReportId, from, to);
  }

  async function openReport(id, from, to) {
    setActiveReportId(id);
    setLoading(id);
    const data = await getPaymentReport(id, from || fromDate, to || toDate);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <div className="card no-print" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>Period</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          <span style={{ color: 'var(--g400)' }}>to</span>
          <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          {activeReportId && (
            <button className="btn btn-primary btn-sm" onClick={() => openReport(activeReportId)}>Apply</button>
          )}
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginLeft: 8 }}>
            {PRESETS.map((p) => (
              <button key={p.label} className="btn btn-sm" onClick={() => applyPreset(p)}>{p.label}</button>
            ))}
          </div>
        </div>
      </div>

      <div className="no-print" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 16 }}>
        {RPT_DEFS.map((r) => (
          <div
            key={r.id}
            onClick={() => openReport(r.id)}
            className="card"
            style={{ cursor: 'pointer', borderTop: `3px solid var(${r.color})`, background: activeReportId === r.id ? 'var(--g50)' : '#fff' }}
          >
            <i className={`ti ${r.icon}`} style={{ color: `var(${r.color})`, fontSize: 20 }}></i>
            <div style={{ fontWeight: 700, fontSize: 13, marginTop: 8 }}>{loading === r.id ? 'Loading...' : r.title}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{r.desc}</div>
          </div>
        ))}
      </div>

      {report && (
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-file"></i> {report.title}
            </div>
            <div className="no-print" style={{ display: 'flex', gap: 8 }}>
              <Link href={`/payments-report-print?reportId=${activeReportId}&from=${fromDate}&to=${toDate}`} target="_blank" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-file-download"></i> Download PDF
              </Link>
              <button className="btn btn-sm" onClick={() => { setReport(null); setActiveReportId(null); }}><i className="ti ti-x"></i> Close</button>
            </div>
          </div>
          <table className="tbl">
            <thead><tr>{report.headers.map((h) => <th key={h}>{h}</th>)}</tr></thead>
            <tbody>
              {report.rows.map((row, i) => (
                <tr key={i}>{row.cols.map((c, j) => <td key={j}>{c}</td>)}</tr>
              ))}
              {report.rows.length === 0 && (
                <tr><td colSpan={report.headers.length} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No data for this period.</td></tr>
              )}
            </tbody>
          </table>
          {report.summary && (
            <div style={{ display: 'flex', gap: 20, justifyContent: 'flex-end', padding: '10px 0', borderTop: '1px solid var(--g200)', marginTop: 10 }}>
              {report.summary.map((s) => (
                <div key={s.label} style={{ textAlign: 'right' }}>
                  <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>{s.label}</div>
                  <div style={{ fontSize: s.emphasize ? 16 : 13, fontWeight: 700, color: s.value < 0 ? 'var(--red)' : s.emphasize ? 'var(--green)' : 'var(--g800)' }}>
                    {s.value < 0 ? '-' : ''}Rs.{Math.abs(s.value).toFixed(2)}
                  </div>
                </div>
              ))}
            </div>
          )}
          {report.total !== null && !report.summary && (
            <div style={{ textAlign: 'right', fontWeight: 700, marginTop: 10, fontSize: 14 }}>
              Total: Rs.{report.total.toFixed(2)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/reports/page.js" << 'VEDA_EOF_MARKER_9f3a'
import { createClient } from '@/lib/supabase-server';
import Link from 'next/link';

async function StatCard({ label, value, color, icon, sub }) {
  return (
    <div className="card" style={{ borderTop: `3px solid var(${color})` }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase', display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className={`ti ${icon}`}></i> {label}
      </div>
      <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

export default async function ReportsPage() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { count: totalPatients },
    { count: registeredToday },
    { count: apptsToday },
    { count: openVisits },
    { count: consultationsToday },
    { count: investigationsToday },
    { count: pendingRx },
    { count: surgeriesScheduled },
    { count: surgeriesCompleted },
    { data: invoicesToday },
    { data: outstandingInvoices },
  ] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }),
    supabase.from('patients').select('*', { count: 'exact', head: true }).gte('created_at', today),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today),
    supabase.from('visits').select('*', { count: 'exact', head: true }).eq('status', 'Open'),
    supabase.from('encounters').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('investigation_orders').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('prescriptions').select('*', { count: 'exact', head: true }).eq('status', 'Pending'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Scheduled'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Completed').eq('scheduled_date', today),
    supabase.from('invoices').select('paid, net').gte('created_at', today),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
  ]);

  const revenueToday = (invoicesToday || []).reduce((s, i) => s + Number(i.paid), 0);
  const outstanding = (outstandingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 12 }}>
        <Link href="/reports-print" target="_blank" className="btn" style={{ textDecoration: 'none' }}>
          <i className="ti ti-file-download"></i> Download Snapshot as PDF
        </Link>
      </div>
      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Patient Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Total Patients" value={totalPatients ?? 0} color="--blue" icon="ti-users" />
        <StatCard label="Registered Today" value={registeredToday ?? 0} color="--blue" icon="ti-user-plus" />
        <StatCard label="Appointments Today" value={apptsToday ?? 0} color="--amber" icon="ti-calendar-event" />
        <StatCard label="Open Visits" value={openVisits ?? 0} color="--green" icon="ti-door-enter" />
      </div>

      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Clinical Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Consultations Today" value={consultationsToday ?? 0} color="--teal" icon="ti-stethoscope" />
        <StatCard label="Investigations Today" value={investigationsToday ?? 0} color="--purple" icon="ti-flask" />
        <StatCard label="Pending Prescriptions" value={pendingRx ?? 0} color="--purple" icon="ti-pill" />
        <StatCard label="Surgeries Scheduled" value={surgeriesScheduled ?? 0} color="--red" icon="ti-scalpel" />
      </div>

      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Financial Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Revenue Today" value={`Rs.${revenueToday.toLocaleString('en-IN')}`} color="--green" icon="ti-cash" />
        <StatCard label="Outstanding Receivables" value={`Rs.${outstanding.toLocaleString('en-IN')}`} color="--red" icon="ti-receipt-2" />
        <StatCard label="Surgeries Completed Today" value={surgeriesCompleted ?? 0} color="--green" icon="ti-circle-check" />
      </div>

      <div className="msg-info" style={{ marginTop: 8 }}>
        <i className="ti ti-info-circle"></i> All figures above are computed live from the actual database -- nothing on this page is hardcoded or simulated.
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/components/GenericReportPrintBody.js" << 'VEDA_EOF_MARKER_9f3a'
// Renders the generic tabular report shape (headers/rows/summary/total)
// that getPaymentReport, getInvestigationReport, and getOptometryReport
// all already return -- one shared print body instead of three copies.
export default function GenericReportPrintBody({ report }) {
  return (
    <>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            {report.headers.map((h) => (
              <th key={h} style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {report.rows.map((row, i) => (
            <tr key={i}>
              {row.cols.map((c, j) => (
                <td key={j} style={{ border: '1px solid #999', padding: 7 }}>{c}</td>
              ))}
            </tr>
          ))}
          {report.rows.length === 0 && (
            <tr><td colSpan={report.headers.length} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No data for this period.</td></tr>
          )}
        </tbody>
      </table>

      {report.summary && (
        <div style={{ display: 'flex', gap: 24, justifyContent: 'flex-end', padding: '10px 0', marginTop: 10 }}>
          {report.summary.map((s) => (
            <div key={s.label} style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 10, color: '#666', textTransform: 'uppercase' }}>{s.label}</div>
              <div style={{ fontSize: s.emphasize ? 15 : 13, fontWeight: 700, color: s.value < 0 ? '#b3261e' : '#1a1a1a' }}>
                {s.value < 0 ? '-' : ''}Rs.{Math.abs(s.value).toFixed(2)}
              </div>
            </div>
          ))}
        </div>
      )}
      {report.total !== null && report.total !== undefined && !report.summary && (
        <div style={{ textAlign: 'right', fontWeight: 700, marginTop: 10, fontSize: 13 }}>
          Total: Rs.{report.total.toFixed(2)}
        </div>
      )}
    </>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/components/ReportLetterhead.js" << 'VEDA_EOF_MARKER_9f3a'
import { getHospitalSettings } from '@/app/print-templates/actions';

function LogoMark({ settings }) {
  if (settings?.logo_data_url) {
    // eslint-disable-next-line @next/next/no-img-element -- print output, not a Next-optimized page
    return <img src={settings.logo_data_url} alt="" style={{ width: 70, height: 70, objectFit: 'contain' }} />;
  }
  return (
    <svg width="70" height="70" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
      <path d="M10 50 Q50 15 90 50 Q50 85 10 50 Z" fill="none" stroke="#1e4e8c" strokeWidth="6" />
      <circle cx="50" cy="50" r="16" fill="#1e4e8c" />
      <path d="M8 52 Q3 60 12 66 Q10 56 8 52 Z" fill="#a6791f" />
    </svg>
  );
}

// Server component -- fetches the hospital's own letterhead details
// (same hospital_settings table every invoice/receipt/discharge summary
// already draws from) and renders the standard header + a document
// title bar. Drop this at the top of any report print route.
export default async function ReportLetterhead({ title, subtitle }) {
  const settings = await getHospitalSettings();

  return (
    <div style={{ fontFamily: 'Arial, Helvetica, sans-serif', color: '#1a1a1a' }}>
      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 6 }}>
        <tbody>
          <tr>
            <td style={{ width: 84, verticalAlign: 'top' }}><LogoMark settings={settings} /></td>
            <td style={{ verticalAlign: 'top' }}>
              <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: '.3px', textDecoration: 'underline' }}>
                {settings.name || 'VEDA EYE HOSPITAL'}
              </div>
              {settings.unit_line && <div style={{ fontSize: 11, fontWeight: 700, marginTop: 2 }}>{settings.unit_line}</div>}
              {settings.regn_no && <div style={{ fontSize: 10, fontWeight: 700 }}>REGN NO : {settings.regn_no}</div>}
            </td>
            <td style={{ textAlign: 'right', verticalAlign: 'top', fontSize: 10.5, lineHeight: 1.5 }}>
              {settings.address_line1 && <>{settings.address_line1}<br /></>}
              {settings.address_line2 && <>{settings.address_line2}<br /></>}
              {settings.city_state_pin && <>{settings.city_state_pin}<br /></>}
              {settings.phone && <>Tel: {settings.phone}<br /></>}
              {settings.email && <strong>{settings.email}</strong>}
            </td>
          </tr>
        </tbody>
      </table>

      <div style={{
        textAlign: 'center', fontSize: 15, fontWeight: 700,
        borderTop: '1.5px solid #333', borderBottom: '1.5px solid #333',
        padding: '8px 0', margin: '10px 0 16px',
      }}>
        {title}
        {subtitle && <div style={{ fontSize: 11, fontWeight: 400, color: '#555', marginTop: 3 }}>{subtitle}</div>}
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/globals.css" << 'VEDA_EOF_MARKER_9f3a'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

/* ── DESIGN TOKENS ──
   Ophthalmic Navy + brass-gold signature, grounded in the subject: a
   slit-lamp instrument palette (deep, precise, calm) with the warm
   brass of an iris used sparingly as the one accent. Semantic badge
   colors (blue/green/red/amber/purple/indigo/cyan/teal) keep their
   existing meaning across the app -- only the values are refined. */
:root {
  --blue: #1e4e8c; --blue-lt: #e7eff8; --blue-dk: #123a66; --blue-mid: #3e71b3;
  --green: #157a4f; --green-lt: #e3f5ec;
  --red: #b3261e; --red-lt: #fbe9e7;
  --amber: #a15c00; --amber-lt: #fbf0dc;
  --purple: #6d28a8; --purple-lt: #f1e7fb;
  --indigo: #3730a3; --indigo-lt: #e7e5fb;
  --cyan: #0b7285; --cyan-lt: #e0f5f8;
  --teal: #0e6b60; --teal-lt: #e1f5f1;
  --g50: #f8f9fa; --g100: #f1f3f5; --g200: #e3e6ea; --g300: #cbd0d6;
  --g400: #97a0aa; --g500: #62707c; --g600: #46525c; --g700: #303a42; --g800: #1c242b; --g900: #10161b;

  /* Signature accent -- the "iris" brass. Used sparingly: logo mark,
     active-nav underline glow, a handful of celebratory highlights.
     Never used for functional/semantic meaning (that's --amber). */
  --accent: #a6791f; --accent-lt: #f6ecd7; --accent-dk: #7d5a12;

  --r: 10px; --r-lg: 16px; --r-sm: 7px;

  --shadow-sm: 0 1px 2px rgba(16, 22, 27, .05), 0 1px 1px rgba(16, 22, 27, .03);
  --shadow-md: 0 4px 14px rgba(16, 22, 27, .07), 0 1px 3px rgba(16, 22, 27, .05);
  --shadow-lg: 0 12px 32px rgba(16, 22, 27, .12), 0 2px 8px rgba(16, 22, 27, .06);

  --font-display-stack: 'Sora', 'Segoe UI', sans-serif;
  --font-body-stack: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

html, body { height: 100%; }
html { -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }

body {
  font-family: var(--font-body-stack);
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
  line-height: 1.5;
}

/* Visible keyboard focus everywhere -- quality floor, not optional. */
a:focus-visible, button:focus-visible, input:focus-visible, select:focus-visible, textarea:focus-visible, [tabindex]:focus-visible {
  outline: 2px solid var(--blue-mid);
  outline-offset: 2px;
  border-radius: 4px;
}

/* Quiet, deliberate scrollbars instead of default browser chrome. */
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--g300); border-radius: 20px; border: 2px solid var(--g50); }
::-webkit-scrollbar-thumb:hover { background: var(--g400); }

/* ── APP SHELL ── */
.app-layout { display: flex; height: 100vh; overflow: hidden; }

/* Dark navy sidebar -- deliberately different register from the rest of
   the (light) app, like an instrument panel: gives the eye a clear,
   permanent anchor for "where am I" that never gets confused with page
   content. Gold accent (--accent) marks the active module. */
.sidebar {
  width: 236px;
  background: #0f1b2e;
  border-right: 1px solid rgba(255, 255, 255, .06);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
  overflow-y: auto;
  min-height: 0;
}
.sb-logo {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 20px 18px;
  border-bottom: 1px solid rgba(255, 255, 255, .08);
  margin-bottom: 4px;
}
.sb-logo-icon {
  width: 36px; height: 36px;
  border-radius: 50%;
  flex-shrink: 0;
  position: relative;
  background:
    radial-gradient(circle at 50% 50%, var(--accent) 0 5px, transparent 5.5px),
    conic-gradient(from 0deg, var(--blue-dk), var(--blue) 35%, var(--blue-mid) 60%, var(--blue-dk) 100%);
  box-shadow: inset 0 0 0 2px rgba(255, 255, 255, .22), 0 0 0 1px rgba(255, 255, 255, .06);
}
.sb-name { font-family: var(--font-display-stack); font-weight: 700; font-size: 14px; letter-spacing: .1px; color: #fff; }
.sb-sub { font-size: 10.5px; color: rgba(255, 255, 255, .45); margin-top: 1px; }
.sb-sec { padding: 18px 18px 8px; font-size: 10.5px; font-weight: 700; color: rgba(232, 200, 140, .82); text-transform: uppercase; letter-spacing: 1.1px; }
.sb-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 16px 8px 15px;
  margin: 1px 8px;
  font-size: 13.5px;
  font-weight: 500;
  color: rgba(255, 255, 255, .88);
  cursor: pointer;
  border-left: 3px solid transparent;
  border-radius: 0 var(--r-sm) var(--r-sm) 0;
  text-decoration: none;
  transition: background .12s ease, color .12s ease;
}
.sb-item:hover { background: rgba(255, 255, 255, .06); color: #fff; }
.sb-item.active { background: rgba(166, 121, 31, .18); color: #fff; border-left-color: var(--accent); font-weight: 700; }
.sb-icon-wrap { width: 18px; text-align: center; flex-shrink: 0; font-size: 14px; }

.main-area { flex: 1; display: flex; flex-direction: column; min-width: 0; height: 100vh; overflow: hidden; }
.topbar {
  background: #fff;
  border-bottom: 1px solid var(--g200);
  box-shadow: var(--shadow-sm);
  padding: 14px 26px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  position: relative;
  z-index: 5;
  flex-shrink: 0;
}
.top-title { font-family: var(--font-display-stack); font-size: 16.5px; font-weight: 700; color: var(--g900); letter-spacing: -.1px; }
.top-sub { font-size: 11px; color: var(--g400); margin-top: 2px; }
.content-area { flex: 1; overflow-y: auto; padding: 26px; min-height: 0; }

/* ── CARDS ── */
.card {
  background: #fff;
  border: 1px solid var(--g200);
  box-shadow: var(--shadow-sm);
  border-radius: var(--r-lg);
  padding: 20px;
  margin-bottom: 16px;
}
.card:last-child { margin-bottom: 0; }
.card-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
.card-title { font-family: var(--font-display-stack); font-size: 14px; font-weight: 700; color: var(--g900); display: flex; align-items: center; gap: 8px; letter-spacing: -.1px; }

/* ── BUTTONS ── */
.btn {
  padding: 9px 16px;
  border-radius: var(--r);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  border: 1px solid var(--g200);
  background: #fff;
  color: var(--g700);
  font-family: var(--font-body-stack);
  transition: background .12s ease, border-color .12s ease, box-shadow .12s ease, transform .08s ease;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.btn:hover { background: var(--g50); border-color: var(--g300); }
.btn:active { transform: translateY(1px); }
.btn:disabled { opacity: .5; cursor: not-allowed; transform: none; }
.btn-primary { background: var(--blue); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-primary:hover { background: var(--blue-dk); box-shadow: var(--shadow-md); }
.btn-green { background: var(--green); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-green:hover { filter: brightness(.92); }
.btn-danger { background: var(--red); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-danger:hover { filter: brightness(.92); }
.btn-sm { padding: 5px 10px; font-size: 11.5px; border-radius: var(--r-sm); }

/* ── BADGES ── */
.badge {
  padding: 2.5px 10px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .1px;
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.b-blue { background: var(--blue-lt); color: var(--blue-dk); }
.b-green { background: var(--green-lt); color: var(--green); }
.b-amber { background: var(--amber-lt); color: var(--amber); }
.b-red { background: var(--red-lt); color: var(--red); }
.b-gray { background: var(--g100); color: var(--g500); }
.b-purple { background: var(--purple-lt); color: var(--purple); }
.b-indigo { background: var(--indigo-lt); color: var(--indigo); }
.b-cyan { background: var(--cyan-lt); color: var(--cyan); }
.b-teal { background: var(--teal-lt); color: var(--teal); }

/* ── FORMS ── */
.fi {
  width: 100%;
  padding: 9px 12px;
  border: 1.5px solid var(--g200);
  border-radius: var(--r);
  font-size: 13px;
  font-family: var(--font-body-stack);
  background: #fff;
  color: var(--g800);
  transition: border-color .12s ease, box-shadow .12s ease;
}
.fi:focus { outline: none; border-color: var(--blue-mid); box-shadow: 0 0 0 3px var(--blue-lt); }
.fi:disabled { background: var(--g50); color: var(--g400); cursor: not-allowed; }
.fi-sm { padding: 6px 10px; font-size: 12px; }
.flbl { font-size: 11.5px; font-weight: 600; color: var(--g600); display: block; margin-bottom: 4px; }

/* Errors and warnings are easy to miss as a quiet inline line, especially
   on long forms -- they now float as an unmissable toast instead,
   regardless of where on the page they're rendered. Success/info stay
   in-flow since they're not the complaint and floating every positive
   confirmation would just add noise. This is pure CSS -- the exact same
   {error && <div className="msg-err">...} pattern used everywhere in the
   app automatically gets this treatment with zero code changes. */
@keyframes msgSlideIn {
  from { opacity: 0; transform: translateX(36px) scale(.97); }
  to { opacity: 1; transform: translateX(0) scale(1); }
}
@keyframes msgShake {
  0%, 100% { transform: translateX(0); }
  20% { transform: translateX(-5px); }
  40% { transform: translateX(5px); }
  60% { transform: translateX(-3px); }
  80% { transform: translateX(3px); }
}

.msg-err, .msg-warn {
  position: fixed;
  right: 26px;
  z-index: 1000;
  min-width: 300px;
  max-width: 440px;
  background: #fff;
  padding: 13px 18px;
  border-radius: var(--r);
  font-size: 13px;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 10px;
  box-shadow: var(--shadow-lg);
  margin-bottom: 0;
}
.msg-err {
  top: 78px;
  color: var(--red);
  border: 1.5px solid var(--red);
  border-left: 5px solid var(--red);
  animation: msgSlideIn .3s cubic-bezier(.2, .8, .3, 1), msgShake .4s ease .3s;
}
.msg-err::before {
  content: '!';
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  width: 21px; height: 21px; border-radius: 50%;
  background: var(--red); color: #fff; font-weight: 800; font-size: 13px;
}
.msg-warn {
  top: 146px;
  color: var(--amber);
  border: 1.5px solid var(--amber);
  border-left: 5px solid var(--amber);
  animation: msgSlideIn .3s cubic-bezier(.2, .8, .3, 1);
}
.msg-warn::before {
  content: '!';
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  width: 21px; height: 21px; border-radius: 50%;
  background: var(--amber); color: #fff; font-weight: 800; font-size: 13px;
}

.msg-info { background: var(--blue-lt); color: var(--blue-dk); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
.msg-success, .msg-ok { background: var(--green-lt); color: var(--green); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }

@media (max-width: 860px) {
  .msg-err, .msg-warn { left: 16px; right: 16px; max-width: none; }
}

/* ── TABLE ── */
.tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.tbl th { text-align: left; padding: 9px 10px; color: var(--g500); font-weight: 700; font-size: 10.5px; text-transform: uppercase; letter-spacing: .4px; background: var(--g50); border-bottom: 1.5px solid var(--g200); }
.tbl th:first-child { border-top-left-radius: var(--r-sm); }
.tbl th:last-child { border-top-right-radius: var(--r-sm); }
.tbl td { padding: 10px; border-bottom: 1px solid var(--g100); color: var(--g700); }
.tbl tbody tr { transition: background .1s ease; }
.tbl tbody tr:hover { background: var(--g50); }

/* ── PRINT ── */
@media print {
  .no-print { display: none !important; }
  body { background: #fff; }
  .card { box-shadow: none; }

  /* App chrome (sidebar, topbar, mobile drawer) never belongs in a
     printout -- this makes any page in the app printable/PDF-able via
     the browser's own Print dialog, not just the dedicated print
     routes. Screen layout relies on height:100vh + overflow:hidden for
     internal scrolling; that would clip a long report to a single
     screen's height when printed, so it's reset to natural flow here. */
  .sidebar, .topbar, .mobile-nav-backdrop, .mobile-menu-btn { display: none !important; }
  .app-layout, .main-area, .content-area {
    display: block !important;
    height: auto !important;
    overflow: visible !important;
  }
  .content-area { padding: 0 !important; }

  /* Consistent margins on every sheet, not just the first. */
  @page {
    size: A4;
    margin: 14mm 12mm;
  }

  /* When a table spills onto a second sheet, its header row (S.No /
     Item / Rate, Structure / RE / LE, etc.) repeats at the top of the
     new page instead of leaving page 2 unlabeled. A single row is
     never split mid-row across the page break -- it either fits
     whole on the current page or moves entirely to the next one. */
  table { page-break-inside: auto; }
  thead { display: table-header-group; }
  tr, td, th { page-break-inside: avoid; }
}

/* ── SMALL SCREENS -- light touch, not a full mobile rework ── */
@media (max-width: 860px) {
  .sidebar { width: 68px; }
  .sb-name, .sb-sub, .sb-sec, .sb-item span:not(.sb-icon-wrap) { display: none; }
  .sb-item { justify-content: center; padding: 10px 0; margin: 1px 6px; }
  .sb-logo { justify-content: center; padding: 16px 0; }
  .content-area { padding: 16px; }
  .topbar { padding: 12px 16px; }
}

/* ── PHONE WIDTHS -- 68px still eats real estate that actually
   matters on a phone (dense tables everywhere), so below this point
   the sidebar goes fully off-canvas as a slide-out drawer instead,
   opened with the hamburger button in the topbar. ── */
.mobile-menu-btn { display: none; }
.mobile-nav-backdrop { display: none; }

@media (max-width: 640px) {
  .mobile-menu-btn { display: flex; }

  .sidebar {
    position: fixed;
    top: 0; left: 0; bottom: 0;
    width: 240px;
    z-index: 60;
    transform: translateX(-100%);
    transition: transform .22s ease;
    box-shadow: 2px 0 24px rgba(0, 0, 0, .25);
  }
  .sidebar.mobile-open { transform: translateX(0); }

  /* Full labels back -- this is a temporary overlay, not the
     permanent squeeze the 68px icon rail is for tablets, so there's
     no reason to sacrifice readability here too. */
  .sb-name, .sb-sub, .sb-sec, .sb-item span:not(.sb-icon-wrap) { display: block; }
  .sb-item { justify-content: flex-start; padding: 8px 16px 8px 15px; margin: 1px 8px; }
  .sb-logo { justify-content: flex-start; padding: 20px 18px; }

  .mobile-nav-backdrop {
    display: block;
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, .4);
    z-index: 55;
  }

  .topbar { padding: 10px 14px; gap: 8px; }
  .top-title { font-size: 15px; }
  .top-sub { display: none; }
  .topbar-userinfo { display: none; }
  .content-area { padding: 12px; }
  .tbl { font-size: 11.5px; }
}
VEDA_EOF_MARKER_9f3a

cat > "app/inventory-report-print/[type]/page.js" << 'VEDA_EOF_MARKER_9f3a'
import ReportLetterhead from '@/app/components/ReportLetterhead';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import {
  getStockValuationReport, getExpiryReport, getConsumptionReport, getVendorPurchaseSummary,
} from '@/app/(main)/inventory/actions';

const TITLES = {
  valuation: 'Stock Valuation Report',
  expiry: 'Expiry Report',
  consumption: 'Consumption Report',
  vendor: 'Vendor Purchase Summary',
};

function fmtDate(d) {
  return d ? new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--';
}
function generatedLine() {
  return `Generated ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;
}

export default async function InventoryReportPrintPage({ params, searchParams }) {
  const { type } = await params;
  const sp = await searchParams;
  const title = TITLES[type];

  if (!title) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>Unknown report type.</div>;
  }

  let subtitle = generatedLine();
  let body;

  if (type === 'valuation') {
    const { rows, totalValue } = await getStockValuationReport();
    body = (
      <>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
          <thead>
            <tr style={{ background: '#e9edf2' }}>
              <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Drug</th>
              <th style={{ border: '1px solid #999', padding: 7 }}>In Stock</th>
              <th style={{ border: '1px solid #999', padding: 7 }}>Avg. Cost</th>
              <th style={{ border: '1px solid #999', padding: 7 }}>Value</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.name}>
                <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{r.name}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{r.qty} {r.unit}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Rs.{r.avgCost.toFixed(2)}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: 600 }}>Rs.{r.value.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</td>
              </tr>
            ))}
            {rows.length === 0 && <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No stock on hand.</td></tr>}
          </tbody>
          <tfoot>
            <tr style={{ fontWeight: 700, background: '#f4f6f8' }}>
              <td colSpan={3} style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Total Stock Value</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Rs.{totalValue.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</td>
            </tr>
          </tfoot>
        </table>
      </>
    );
  }

  if (type === 'expiry') {
    const days = sp?.days || '90';
    subtitle = `Batches expiring within ${days} days -- ${generatedLine()}`;
    const rows = await getExpiryReport(days);
    body = (
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Drug</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Batch</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Expiry Date</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Days Left</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Qty</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((e, i) => (
            <tr key={i}>
              <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{e.name}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{e.batchNumber || '--'}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{fmtDate(e.expiryDate)}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center', fontWeight: 600 }}>{e.daysLeft}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{e.qty} {e.unit}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: '#999' }}>Nothing expiring in this window.</td></tr>}
        </tbody>
      </table>
    );
  }

  if (type === 'consumption') {
    const from = sp?.from, to = sp?.to;
    subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- ${generatedLine()}`;
    const rows = await getConsumptionReport(from, to);
    body = (
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Drug</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Consumed</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((c, i) => (
            <tr key={i}>
              <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{c.name}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center', fontWeight: 600 }}>{c.consumed} {c.unit}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={2} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No dispensing recorded in this range.</td></tr>}
        </tbody>
      </table>
    );
  }

  if (type === 'vendor') {
    const from = sp?.from, to = sp?.to;
    subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- ${generatedLine()}`;
    const rows = await getVendorPurchaseSummary(from, to);
    body = (
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
        <thead>
          <tr style={{ background: '#e9edf2' }}>
            <th style={{ border: '1px solid #999', padding: 7, textAlign: 'left' }}>Vendor</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Bills</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Total</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Paid</th>
            <th style={{ border: '1px solid #999', padding: 7 }}>Unpaid</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((v, i) => (
            <tr key={i}>
              <td style={{ border: '1px solid #999', padding: 7, fontWeight: 600 }}>{v.name}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{v.bills}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: 600 }}>Rs.{v.total.toLocaleString('en-IN')}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>Rs.{v.paid.toLocaleString('en-IN')}</td>
              <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: v.unpaid > 0 ? 600 : 400 }}>Rs.{v.unpaid.toLocaleString('en-IN')}</td>
            </tr>
          ))}
          {rows.length === 0 && <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: '#999' }}>No purchases in this range.</td></tr>}
        </tbody>
      </table>
    );
  }

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title={title} subtitle={subtitle} />
      {body}
      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report.
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/investigation-report-print/page.js" << 'VEDA_EOF_MARKER_9f3a'
import ReportLetterhead from '@/app/components/ReportLetterhead';
import GenericReportPrintBody from '@/app/components/GenericReportPrintBody';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import { getInvestigationReport } from '@/app/(main)/investigation/actions';

function fmtDate(d) {
  return d ? new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--';
}

export default async function InvestigationReportPrintPage({ searchParams }) {
  const sp = await searchParams;
  const { reportId, from, to } = sp || {};

  if (!reportId || !from || !to) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>Missing report parameters.</div>;
  }

  const report = await getInvestigationReport(reportId, from, to);
  const subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- Generated ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title={report.title} subtitle={subtitle} />
      <GenericReportPrintBody report={report} />
      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report.
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/optometry-report-print/page.js" << 'VEDA_EOF_MARKER_9f3a'
import ReportLetterhead from '@/app/components/ReportLetterhead';
import GenericReportPrintBody from '@/app/components/GenericReportPrintBody';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import { getOptometryReport } from '@/app/(main)/optometry-reports/actions';

function fmtDate(d) {
  return d ? new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--';
}

export default async function OptometryReportPrintPage({ searchParams }) {
  const sp = await searchParams;
  const { reportId, from, to } = sp || {};

  if (!reportId || !from || !to) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>Missing report parameters.</div>;
  }

  const report = await getOptometryReport(reportId, from, to);
  const subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- Generated ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title={report.title} subtitle={subtitle} />
      <GenericReportPrintBody report={report} />
      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report.
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/payments-report-print/page.js" << 'VEDA_EOF_MARKER_9f3a'
import ReportLetterhead from '@/app/components/ReportLetterhead';
import GenericReportPrintBody from '@/app/components/GenericReportPrintBody';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';
import { getPaymentReport } from '@/app/(main)/payments/actions';

function fmtDate(d) {
  return d ? new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--';
}

export default async function PaymentsReportPrintPage({ searchParams }) {
  const sp = await searchParams;
  const { reportId, from, to } = sp || {};

  if (!reportId || !from || !to) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>Missing report parameters.</div>;
  }

  const report = await getPaymentReport(reportId, from, to);
  const subtitle = `${fmtDate(from)} to ${fmtDate(to)} -- Generated ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title={report.title} subtitle={subtitle} />
      <GenericReportPrintBody report={report} />
      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        This is a computer-generated report.
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/reports-print/page.js" << 'VEDA_EOF_MARKER_9f3a'
import { createClient } from '@/lib/supabase-server';
import ReportLetterhead from '@/app/components/ReportLetterhead';
import PrintButton from '@/app/invoice-print/[invoiceId]/print-button';

function StatRow({ label, value }) {
  return (
    <tr>
      <td style={{ border: '1px solid #999', padding: 7, color: '#444' }}>{label}</td>
      <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right', fontWeight: 700 }}>{value}</td>
    </tr>
  );
}

export default async function ReportsSnapshotPrintPage() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { count: totalPatients }, { count: registeredToday }, { count: apptsToday }, { count: openVisits },
    { count: consultationsToday }, { count: investigationsToday }, { count: pendingRx },
    { count: surgeriesScheduled }, { count: surgeriesCompleted },
    { data: invoicesToday }, { data: outstandingInvoices },
  ] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }),
    supabase.from('patients').select('*', { count: 'exact', head: true }).gte('created_at', today),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today),
    supabase.from('visits').select('*', { count: 'exact', head: true }).eq('status', 'Open'),
    supabase.from('encounters').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('investigation_orders').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('prescriptions').select('*', { count: 'exact', head: true }).eq('status', 'Pending'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Scheduled'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Completed').eq('scheduled_date', today),
    supabase.from('invoices').select('paid, net').gte('created_at', today),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
  ]);

  const revenueToday = (invoicesToday || []).reduce((s, i) => s + Number(i.paid), 0);
  const outstanding = (outstandingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);
  const subtitle = `Hospital Snapshot -- ${new Date().toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' })}`;

  return (
    <div style={{ maxWidth: 780, margin: '0 auto', padding: 24 }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 16 }}>
        <PrintButton />
      </div>
      <ReportLetterhead title="Hospital Snapshot Report" subtitle={subtitle} />

      <div style={{ fontSize: 12, fontWeight: 700, color: '#444', textTransform: 'uppercase', margin: '16px 0 8px' }}>Patient Statistics</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 16 }}>
        <tbody>
          <StatRow label="Total Patients" value={totalPatients ?? 0} />
          <StatRow label="Registered Today" value={registeredToday ?? 0} />
          <StatRow label="Appointments Today" value={apptsToday ?? 0} />
          <StatRow label="Open Visits" value={openVisits ?? 0} />
        </tbody>
      </table>

      <div style={{ fontSize: 12, fontWeight: 700, color: '#444', textTransform: 'uppercase', margin: '16px 0 8px' }}>Clinical Statistics</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 16 }}>
        <tbody>
          <StatRow label="Consultations Today" value={consultationsToday ?? 0} />
          <StatRow label="Investigations Today" value={investigationsToday ?? 0} />
          <StatRow label="Pending Prescriptions" value={pendingRx ?? 0} />
          <StatRow label="Surgeries Scheduled" value={surgeriesScheduled ?? 0} />
        </tbody>
      </table>

      <div style={{ fontSize: 12, fontWeight: 700, color: '#444', textTransform: 'uppercase', margin: '16px 0 8px' }}>Financial Statistics</div>
      <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 16 }}>
        <tbody>
          <StatRow label="Revenue Today" value={`Rs.${revenueToday.toLocaleString('en-IN')}`} />
          <StatRow label="Outstanding Receivables" value={`Rs.${outstanding.toLocaleString('en-IN')}`} />
          <StatRow label="Surgeries Completed Today" value={surgeriesCompleted ?? 0} />
        </tbody>
      </table>

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 10.5, color: '#999' }}>
        All figures computed live from the database at the time this report was generated.
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

echo "--- Files written ---"
find "app/inventory-report-print" "app/investigation-report-print" "app/optometry-report-print" "app/payments-report-print" "app/reports-print" -type f
echo ""

git add "app/(main)/inventory/reports/page.js" "app/(main)/investigation/reports/page.js" "app/(main)/optometry-reports/page.js" "app/(main)/payments/reports/payment-reports-tab.js" "app/(main)/reports/page.js" "app/components/GenericReportPrintBody.js" "app/components/ReportLetterhead.js" "app/globals.css" "app/inventory-report-print/[type]/page.js" "app/investigation-report-print/page.js" "app/optometry-report-print/page.js" "app/payments-report-print/page.js" "app/reports-print/page.js" "app/components/DownloadPdfButton.js"

echo "--- Git status ---"
git status
echo ""

git commit -m "Replace raw browser-print with proper letterhead PDF reports: hospital name/logo/address on every report, each Inventory report downloads as its own separate PDF, same treatment for Payments/Investigation/Optometry/general Reports"

git push origin main

echo ""
echo "Pushed. Vercel will auto-build main -> both portal.vedaeyehospital.com and training.vedaeyehospital.com."
echo ""
echo "What changed for you:"
echo "  - Every report PDF now has a real letterhead: hospital name, logo,"
echo "    address, registration number -- the same details already used on"
echo "    your invoices/receipts/discharge summaries (from Print Templates"
echo "    > Hospital Settings, so if that's filled in, it'll show correctly)"
echo "  - Inventory > Reports: each of the 4 reports (Stock Valuation,"
echo "    Expiry, Consumption, Vendor Purchase Summary) now has its OWN"
echo "    'Download PDF' button and produces its own separate document --"
echo "    not one bundled printout"
echo "  - Payments / Investigation / Optometry Reports: same treatment --"
echo "    whichever report you have open downloads as its own letterhead"
echo "    PDF, generated fresh with the exact date range you selected"
echo "  - General Reports page: 'Download Snapshot as PDF' now produces a"
echo "    proper letterhead document instead of a raw screen printout"
