'use client';

import { useState, useEffect, useCallback } from 'react';
import Link from 'next/link';
import InventoryTabs from './inventory-tabs';
import { getDashboardSummary, searchItemStock, markPurchasePaid } from './actions';

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

const STATUS_BADGE = { OK: 'b-green', Low: 'b-amber', Out: 'b-red' };

export default function InventoryDashboardPage() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [searching, setSearching] = useState(false);

  const refresh = useCallback(async () => {
    setData(await getDashboardSummary());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  useEffect(() => {
    if (query.trim().length < 2) { setResults([]); return; }
    setSearching(true);
    const t = setTimeout(async () => {
      setResults(await searchItemStock(query));
      setSearching(false);
    }, 250);
    return () => clearTimeout(t);
  }, [query]);

  async function handleMarkPaid(id) {
    await markPurchasePaid(id);
    refresh();
  }

  if (loading || !data) {
    return <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading...</div>;
  }

  const { stats, shortages, recentPurchases, unpaidPurchases, unpaidTotal, unpaidCount } = data;

  return (
    <div>
      <InventoryTabs />

      {/* BIG PRIMARY ACTION */}
      <div className="card" style={{ marginBottom: 16, padding: '18px 20px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', background: 'linear-gradient(135deg, var(--blue), var(--teal))' }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 800, color: '#fff' }}>Received new stock from a vendor?</div>
          <div style={{ fontSize: 12, color: 'rgba(255,255,255,.85)', marginTop: 2 }}>Log the vendor bill once, add every item on it in one go.</div>
        </div>
        <Link href="/inventory/material-input" style={{ textDecoration: 'none' }}>
          <button className="btn" style={{ background: '#fff', color: 'var(--blue)', fontWeight: 800, fontSize: 15, padding: '12px 26px', border: 'none' }}>
            <i className="ti ti-plus" style={{ marginRight: 6 }}></i> New Material In
          </button>
        </Link>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Tracked items" value={stats.totalItems} sub="Drugs with stock tracking on" color="var(--blue)" />
        <KpiCard label="Low stock" value={stats.lowStock} sub="At or below reorder level" color="var(--amber)" />
        <KpiCard label="Out of stock" value={stats.outOfStock} sub="Zero or negative on hand" color="var(--red)" />
        <KpiCard label="Unpaid bills" value={unpaidCount} sub={`Rs.${unpaidTotal.toLocaleString('en-IN')} outstanding`} color="var(--purple)" />
      </div>

      {/* STOCK LOOKUP */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Check Stock of Any Item</div>
        <input
          className="fi" placeholder="Start typing a drug name..." value={query}
          onChange={(e) => setQuery(e.target.value)} style={{ maxWidth: 400 }}
        />
        {searching && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>Searching...</div>}
        {results.length > 0 && (
          <div style={{ marginTop: 10 }}>
            {results.map((r) => (
              <div key={r.itemId} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                <div>
                  <span style={{ fontWeight: 600 }}>{r.name}</span>
                  <span style={{ fontSize: 11, color: 'var(--g500)', marginLeft: 8 }}>{r.generic}</span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <span style={{ fontWeight: 700 }}>{r.onHand} {r.unit}</span>
                  <span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* UNPAID BILLS ALERT */}
      {unpaidCount > 0 && (
        <div className="card" style={{ marginBottom: 16, borderLeft: '3px solid var(--red)' }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Unpaid Vendor Bills -- Rs.{unpaidTotal.toLocaleString('en-IN')} outstanding
          </div>
          <table className="tbl">
            <thead><tr><th>Vendor</th><th>Bill No.</th><th>Bill Date</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {unpaidPurchases.map((p) => (
                <tr key={p.id}>
                  <td style={{ fontWeight: 600 }}>{p.vendorName}</td>
                  <td>{p.billNumber}</td>
                  <td>{new Date(p.billDate).toLocaleDateString('en-IN')}</td>
                  <td>{p.billAmount ? `Rs.${p.billAmount.toLocaleString('en-IN')}` : <span style={{ color: 'var(--g400)' }}>Not entered</span>}</td>
                  <td><button className="btn btn-sm btn-primary" onClick={() => handleMarkPaid(p.id)}>Mark Paid</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 16 }}>
        {/* ITEMS RUNNING SHORT */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-alert-circle" style={{ color: 'var(--amber)' }}></i> Items Running Short
          </div>
          <table className="tbl">
            <thead><tr><th>Drug</th><th>On Hand</th><th>Reorder At</th><th>Status</th></tr></thead>
            <tbody>
              {shortages.map((r) => (
                <tr key={r.itemId}>
                  <td style={{ fontWeight: 600 }}>{r.name}</td>
                  <td style={{ fontWeight: 700, color: r.stockStatus === 'Out' ? 'var(--red)' : 'var(--amber)' }}>{r.onHand} {r.unit}</td>
                  <td>{r.reorderLevel}</td>
                  <td><span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span></td>
                </tr>
              ))}
              {shortages.length === 0 && (
                <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Nothing running short right now.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        {/* LAST 5 VENDOR BILLS */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-receipt-2" style={{ color: 'var(--green)' }}></i> Last 5 Vendor Bills
          </div>
          {recentPurchases.map((p) => (
            <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <div style={{ fontWeight: 600 }}>{p.vendorName}</div>
                <div style={{ color: 'var(--g500)', fontSize: 11 }}>{p.billNumber} · {new Date(p.billDate).toLocaleDateString('en-IN')}</div>
              </div>
              <span className={`badge ${p.paymentStatus === 'Paid' ? 'b-green' : 'b-red'}`}>{p.paymentStatus}</span>
            </div>
          ))}
          {recentPurchases.length === 0 && (
            <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>No purchases recorded yet.</div>
          )}
          <div style={{ marginTop: 10, textAlign: 'right' }}>
            <Link href="/inventory/material-input" style={{ fontSize: 12, color: 'var(--blue)' }}>View all purchases &rarr;</Link>
          </div>
        </div>
      </div>
    </div>
  );
}
