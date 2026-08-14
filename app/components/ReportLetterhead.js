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
