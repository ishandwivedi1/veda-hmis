'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getOpticalDashboardSummary } from '../actions';

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`;
}

function KpiCard({ icon, label, value, sub, color, onClick }) {
  return (
    <div
      className="card"
      onClick={onClick}
      style={{ flex: 1, minWidth: 200, cursor: onClick ? 'pointer' : 'default', borderTop: `3px solid ${color}` }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
        <i className={`ti ${icon}`} style={{ fontSize: 18, color }}></i>
        <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--g500)' }}>{label}</div>
      </div>
      <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 26, fontWeight: 700, color: 'var(--g900)' }}>{value}</div>
      {sub && <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

export default function OpticalDashboardTab() {
  const router = useRouter();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => { load(); }, []);
  async function load() {
    setLoading(true);
    setData(await getOpticalDashboardSummary());
    setLoading(false);
  }

  if (loading || !data) {
    return <div className="card"><div style={{ fontSize: 13, color: 'var(--g400)' }}>Loading dashboard...</div></div>;
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 20 }}>
        <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 20, fontWeight: 700, color: 'var(--g900)' }}>
          <i className="ti ti-sunglasses" style={{ color: 'var(--blue)', marginRight: 8 }}></i>Optical Shop Overview
        </div>
        <button className="btn btn-primary" onClick={() => router.push('/optical/book')}>
          <i className="ti ti-glasses"></i> Book Spectacles
        </button>
      </div>

      <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', marginBottom: 20 }}>
        <KpiCard
          icon="ti-file-plus" label="Today's Sales" color="var(--blue)"
          value={data.today.salesCount}
          sub={`${fmt(data.today.salesValue)} billed today`}
          onClick={() => router.push('/optical/history')}
        />
        <KpiCard
          icon="ti-cash" label="Collected Today" color="var(--green)"
          value={fmt(data.today.collected)}
          sub={Object.entries(data.today.collectedByMode).map(([m, v]) => `${m} ${fmt(v)}`).join(' -- ') || 'Nothing collected yet'}
          onClick={() => router.push('/optical/payments')}
        />
        <KpiCard
          icon="ti-clock" label="Outstanding Orders" color="var(--red)"
          value={data.outstanding.count}
          sub={`${fmt(data.outstanding.value)} still due`}
          onClick={() => router.push('/optical/collect')}
        />
        <KpiCard
          icon="ti-piggy-bank" label="Advance Held" color="var(--purple)"
          value={fmt(data.advanceHeld)}
          sub="Unapplied customer balances"
          onClick={() => router.push('/optical/advance')}
        />
      </div>

      <div style={{ marginBottom: 20 }}>
        <KpiCard
          icon="ti-calendar" label="This Month" color="var(--indigo)"
          value={fmt(data.month.salesValue)}
          sub={`${data.month.salesCount} order${data.month.salesCount === 1 ? '' : 's'} billed since the 1st`}
        />
      </div>

      <div className="card">
        <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 15, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-clock" style={{ color: 'var(--red)' }}></i> Pending Orders
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12 }}>Across every customer, sorted by how long they've been waiting.</div>
        {data.outstanding.needsAttention.length === 0 ? (
          <div style={{ fontSize: 13, color: 'var(--g400)' }}>Nothing outstanding right now -- every order is settled.</div>
        ) : (
          data.outstanding.needsAttention.map((b) => (
            <div
              key={b.id}
              onClick={() => router.push(`/optical/collect?saleId=${b.id}`)}
              style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
            >
              <div>
                <div style={{ fontWeight: 600, fontSize: 13.5 }}>{b.sale_number} <span style={{ fontWeight: 400, color: 'var(--g500)' }}>-- {b.displayName}</span></div>
                <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>{b.status}</div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div style={{ fontWeight: 700, color: 'var(--red)' }}>{fmt(b.outstanding)}</div>
                <span className="badge" style={{ background: b.daysPending > 7 ? 'var(--red-lt)' : 'var(--amber-lt)', color: b.daysPending > 7 ? 'var(--red)' : 'var(--amber)', fontSize: 10 }}>
                  {b.daysPending}d pending
                </span>
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
