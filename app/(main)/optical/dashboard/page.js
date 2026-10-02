import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';
import DayOpenBar from '@/app/components/DayOpenBar';
import { OpticalHeader } from '../optical-ui';

export const dynamic = 'force-dynamic';

// Optical Dashboard (Oct 2026): two boxes -- Book New Order and Finalize
// Existing Order. Bills and Payments have their own screens.
//
// Links here use prefetch={false}: Book / Finalize are server-rendered
// pages, and Next.js would otherwise pre-render one of them for EVERY
// order in the list (plus Book) as soon as the dashboard opened -- 10+
// hidden server requests competing with the click you actually make.
//
// ONE database call, made while the page renders on the server (nothing
// extra from the browser): ui_optical_bills with a status that matches no
// bill, so it returns just the day-open status and the bookings awaiting
// delivery (with advance on file) -- no bill rows.
const money = (n) => `₹${(Math.round((Number(n) || 0) * 100) / 100).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateIST = (d) => new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });

export default async function OpticalDashboardPage() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_optical_bills', {
    p_query: null, p_status: '__dashboard__', p_from: null, p_to: null, p_full: true,
  });
  const bookings = data?.bookings || [];
  const box = { display: 'flex', flexDirection: 'column', padding: 20, minHeight: 320 };
  const boxTitle = { display: 'flex', alignItems: 'center', gap: 10, fontSize: 17, fontWeight: 700, marginBottom: 6 };
  const iconWrap = (bg, color) => ({ width: 40, height: 40, borderRadius: 10, background: bg, color, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 20, flexShrink: 0 });

  return (
    <div>
      <OpticalHeader title="Optical Dashboard" />
      <DayOpenBar status={data?.day || null} note="booking or finalizing orders is blocked" source="Optical Shop" />
      {error && <div className="card" style={{ color: 'var(--red)', marginBottom: 12 }}>{error.message}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(300px, 1fr))', gap: 16 }}>
        {/* Box 1: Book New Order */}
        <div className="card" style={box}>
          <div style={boxTitle}>
            <span style={iconWrap('var(--blue-lt)', 'var(--blue)')}><i className="ti ti-eyeglass"></i></span>
            Book New Order
          </div>
          <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 16 }}>
            Take a spectacle order for a patient or walk-in customer, with prescription, frame / lens details and advance. It is billed when you finalize it at delivery.
          </div>
          <div style={{ flex: 1 }}></div>
          <Link href="/optical/book" prefetch={false} className="btn btn-primary" style={{ textDecoration: 'none', justifyContent: 'center', padding: '12px 16px', fontSize: 15 }}>
            <i className="ti ti-plus"></i> Book New Order
          </Link>
        </div>

        {/* Box 2: Finalize Existing Order */}
        <div className="card" style={box}>
          <div style={boxTitle}>
            <span style={iconWrap('var(--green-lt)', 'var(--green)')}><i className="ti ti-package"></i></span>
            Finalize Existing Order
            <span className="badge b-blue" style={{ marginLeft: 'auto' }}>{bookings.length} awaiting</span>
          </div>
          <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 12 }}>
            Deliver a booked order: confirm items and price, and its bill is created.
          </div>
          {bookings.length === 0 ? (
            <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--g400)', fontSize: 13, border: '1px dashed var(--g200)', borderRadius: 10, padding: 20 }}>
              No orders awaiting delivery.
            </div>
          ) : (
            <div style={{ maxHeight: 420, overflowY: 'auto', display: 'flex', flexDirection: 'column', gap: 6 }}>
              {bookings.map((b) => (
                <Link key={b.id} href={`/optical/finalize-order?orderId=${b.id}`} prefetch={false}
                  style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', border: '1px solid var(--g200)', borderRadius: 10, background: 'var(--g50)', textDecoration: 'none', color: 'var(--g800)' }}>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ fontWeight: 600, fontSize: 13.5 }}>{b.customer}</div>
                    <div style={{ fontSize: 11.5, color: 'var(--g500)' }}>
                      <span style={{ fontFamily: 'monospace' }}>{b.order_number}</span> · booked {dateIST(b.created_at)}
                    </div>
                  </div>
                  <div style={{ textAlign: 'right', fontSize: 12 }}>
                    <div style={{ fontWeight: 600 }}>{money(b.net)}</div>
                    <div style={{ color: 'var(--g500)' }}>Advance {money(b.advanceOnFile)}</div>
                  </div>
                  <span className="btn btn-sm btn-primary">Finalize</span>
                </Link>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
