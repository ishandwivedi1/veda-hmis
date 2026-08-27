'use client';

import { useState, useEffect, Suspense } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useRouter, useSearchParams } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '@/app/(main)/appointments/actions';
import { createWalkInVisit, getSurgeryTypeOptions, getPatientById, getLastVisitInfo } from '@/app/(main)/visits/actions';
import VisitCreatedModal from '@/app/components/VisitCreatedModal';

function fmtDate(iso) {
  if (!iso) return '--';
  return new Date(iso).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function daysAgo(iso) {
  if (!iso) return null;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 86400000);
}

// Shown automatically the moment a patient is selected -- front desk
// needs to see this without asking, so they can bill a Follow-up
// correctly (free within 15 days of the last New Consultation, billed
// after that window closes).
function LastVisitPanel({ loading, info }) {
  if (loading) {
    return <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 8 }}><i className="ti ti-loader-2"></i> Checking last visit...</div>;
  }
  if (!info) return null;
  if (!info.hasPriorVisit) {
    return <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 8 }}><i className="ti ti-info-circle"></i> First visit -- no prior visits on record.</div>;
  }

  const ago = daysAgo(info.lastVisitDate);

  return (
    <div style={{ marginTop: 8, padding: '8px 12px', borderRadius: 8, background: 'var(--g50, #f7f8fa)', border: '1px solid var(--g200)', fontSize: 12 }}>
      <div>
        <i className="ti ti-history" style={{ color: 'var(--g500)' }}></i>{' '}
        Last visit: <strong>{fmtDate(info.lastVisitDate)}</strong> ({info.lastVisitType}) -- {ago === 0 ? 'today' : `${ago} day${ago === 1 ? '' : 's'} ago`}
      </div>
      {info.freeFollowUpUntil && (
        <div style={{ marginTop: 4 }}>
          {info.withinFreeWindow ? (
            <span className="badge b-green">
              <i className="ti ti-circle-check"></i> Free follow-up until {fmtDate(info.freeFollowUpUntil)}
            </span>
          ) : (
            <span className="badge b-amber">
              <i className="ti ti-alert-circle"></i> Free follow-up window ended {fmtDate(info.freeFollowUpUntil)} -- bill consultation charge
            </span>
          )}
        </div>
      )}
    </div>
  );
}

export default function NewVisitPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <NewVisitForm />
    </Suspense>
  );
}

function NewVisitForm() {
  const searchParams = useSearchParams();
  const prefillPatientId = searchParams.get('patientId');
  const prefillVisitType = searchParams.get('visitType');

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searched, setSearched] = useState(false);
  const [prefillLoading, setPrefillLoading] = useState(!!prefillPatientId);
  const [prefillError, setPrefillError] = useState('');
  const [lastVisitInfo, setLastVisitInfo] = useState(null);
  const [lastVisitLoading, setLastVisitLoading] = useState(false);

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [visitType, setVisitType] = useState(prefillVisitType === 'Surgery' ? 'Surgery' : 'New Consultation');
  const [referralSource, setReferralSource] = useState('Walk-in');
  const [priority, setPriority] = useState('Routine');
  const [surgeryTypes, setSurgeryTypes] = useState([]);
  const [surgeryType, setSurgeryType] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [createdVisitInfo, setCreatedVisitInfo] = useState(null);
  const router = useRouter();

  useEffect(() => {
    getDoctors().then((list) => {
      setDoctors(list);
      // Default to Dr. Nisha Bachkheti (the hospital's sole/primary
      // doctor) instead of leaving this blank -- an unselected doctor
      // here is what leaves the OPD Case Sheet's doctor name blank
      // later, since the case sheet reads visits.doctor_id directly.
      // Front desk can still change it if a different doctor applies.
      setDoctorId((prev) => {
        if (prev) return prev;
        const defaultDoctor = list.find((d) => d.full_name?.toLowerCase().includes('nisha bachkheti'));
        return defaultDoctor ? defaultDoctor.id : prev;
      });
    });
    getSurgeryTypeOptions().then(setSurgeryTypes);
  }, []);

  useEffect(() => {
    if (!prefillPatientId) return;
    let cancelled = false;
    setPrefillLoading(true);
    getPatientById(prefillPatientId).then((patient) => {
      if (cancelled) return;
      setPrefillLoading(false);
      if (patient) {
        setSelectedPatient(patient);
      } else {
        setPrefillError('Could not load that patient -- search for them below instead.');
      }
    });
    return () => { cancelled = true; };
  }, [prefillPatientId]);

  // Shows automatically the moment a patient is selected -- front desk
  // shouldn't have to look this up separately to bill a Follow-up
  // correctly.
  useEffect(() => {
    if (!selectedPatient?.id) { setLastVisitInfo(null); return; }
    let cancelled = false;
    setLastVisitLoading(true);
    getLastVisitInfo(selectedPatient.id).then((info) => {
      if (!cancelled) { setLastVisitInfo(info); setLastVisitLoading(false); }
    });
    return () => { cancelled = true; };
  }, [selectedPatient?.id]);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForBooking(searchQuery.trim());
    setSearchResults(results);
    setSearched(true);
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); setSearched(false); return; }
    const t = setTimeout(async () => {
      const results = await searchPatientsForBooking(q);
      setSearchResults(results);
      setSearched(true);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  function goToFullRegistration() {
    const isMobile = /^\d{6,}$/.test(searchQuery.trim());
    const params = new URLSearchParams({
      returnTo: 'visit',
      prefillFirstName: isMobile ? '' : searchQuery.trim().split(' ')[0] || '',
      prefillLastName: isMobile ? '' : searchQuery.trim().split(' ').slice(1).join(' ') || '',
      prefillMobile: isMobile ? searchQuery.trim() : '',
    });
    router.push(`/patients/new?${params.toString()}`);
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!selectedPatient) {
      setError('Search and select a registered patient.');
      return;
    }
    if (visitType === 'Surgery' && !surgeryType) {
      setError('Select the type of surgery.');
      return;
    }

    setLoading(true);
    const result = await createWalkInVisit({
      patientId: selectedPatient.id,
      doctorId: doctorId || null,
      visitType,
      referralSource,
      priority,
      surgeryType,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    // Surgery and Surgery Evaluation both land directly on the
    // patient's Surgical Journey case -- that's the one place a
    // front-desk executive can see exactly what's needed next
    // (booking, payment, check-in status, awaiting confirmation),
    // rather than a generic Patient Check-In screen. Falls back to
    // Patient Check-In's own "Register Surgery Directly" resolver only
    // if genuinely no case exists at all for this patient.
    if (['Surgery', 'Surgery Evaluation'].includes(visitType)) {
      if (result.surgicalCaseId) {
        router.push(`/surgical-journey/${result.surgicalCaseId}`);
      } else {
        router.push(`/patient-checkin?patientId=${selectedPatient.id}`);
      }
      return;
    }

    // OPD Procedure Only skips the doctor queue entirely (see
    // create_walk_in_visit) and lands straight on the patient's OPD
    // Procedures workspace, where Check-In is now unlocked since an
    // active visit exists.
    if (visitType === 'OPD Procedure Only') {
      router.push(`/opd-procedures/${selectedPatient.id}`);
      return;
    }

    // Post-operative Review never needs an invoice created at front
    // desk -- skip the Create Invoice prompt entirely and go straight
    // back to the dashboard.
    if (visitType === 'Post-operative Review') {
      router.push('/front-office-dashboard?visitCreated=1');
      return;
    }

    setCreatedVisitInfo({ patient: selectedPatient, visit: result.visit });
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-door-enter" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Create Walk-in Visit
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 20 }}>
          For patients arriving without a prior appointment.
        </div>

        {error && <div className="msg-err">{error}</div>}
        {prefillError && <div className="msg-err">{prefillError}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 16 }}>
            <label className="flbl">Find patient (name, UHID, or mobile) *</label>
            {prefillLoading ? (
              <div style={{ padding: '8px 12px', color: 'var(--g500)', fontSize: 13 }}>
                <i className="ti ti-loader-2"></i> Loading patient...
              </div>
            ) : selectedPatient ? (
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: 'var(--blue-lt)',
                  padding: '8px 12px',
                  borderRadius: 8,
                }}
              >
                <span>
                  <strong>{formatPatientName(selectedPatient)}</strong>
                  {' -- '}
                  {selectedPatient.uhid}
                </span>
                <button
                  type="button"
                  className="btn"
                  style={{ padding: '4px 10px' }}
                  onClick={() => setSelectedPatient(null)}
                >
                  Change
                </button>
              </div>
            ) : null}
            {selectedPatient && <LastVisitPanel loading={lastVisitLoading} info={lastVisitInfo} />}
            {!prefillLoading && !selectedPatient && (
              <>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input
                    className="fi"
                    value={searchQuery}
                    onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }}
                    placeholder="Type to search..."
                  />
                  <button type="button" className="btn" onClick={handleSearch}>
                    Search
                  </button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 6 }}>
                    {searchResults.map((p) => (
                      <div
                        key={p.id}
                        onClick={() => pickPatient(p)}
                        style={{
                          padding: '8px 12px',
                          cursor: 'pointer',
                          borderBottom: '1px solid var(--g100)',
                          fontSize: 13,
                        }}
                      >
                        <strong>{formatPatientName(p)}</strong> -- {p.uhid} -- {p.mobile}
                      </div>
                    ))}
                  </div>
                )}
                {searched && searchResults.length === 0 && (
                  <div style={{ fontSize: 12, marginTop: 8 }}>
                    No match for &quot;{searchQuery || 'that search'}&quot;.{' '}
                    <button
                      type="button"
                      onClick={goToFullRegistration}
                      style={{ color: 'var(--blue)', background: 'none', border: 'none', padding: 0, cursor: 'pointer', textDecoration: 'underline', fontSize: 12 }}
                    >
                      Register this patient
                    </button>
                  </div>
                )}
              </>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: visitType === 'Surgery' ? '1fr 1fr 1fr' : '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => { setVisitType(e.target.value); if (e.target.value !== 'Surgery') setSurgeryType(''); }}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Surgery Evaluation</option>
                <option>OPD Procedure Only</option>
                <option>Surgery</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
              </select>
            </div>
            {visitType === 'Surgery' && (
              <div>
                <label className="flbl">Type of surgery</label>
                <select className="fi" value={surgeryType} onChange={(e) => setSurgeryType(e.target.value)}>
                  <option value="">-- Select --</option>
                  {surgeryTypes.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                </select>
              </div>
            )}
            <div>
              <label className="flbl">Doctor</label>
              <select className="fi" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
                <option value="">-- Any / Not decided --</option>
                {doctors.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 20 }}>
            <div>
              <label className="flbl">Referral source</label>
              <select className="fi" value={referralSource} onChange={(e) => setReferralSource(e.target.value)}>
                <option>Walk-in</option>
                <option>Doctor referral</option>
                <option>Camp / outreach</option>
                <option>Previous patient</option>
              </select>
            </div>
            <div>
              <label className="flbl">Priority</label>
              <select className="fi" value={priority} onChange={(e) => setPriority(e.target.value)}>
                <option>Routine</option>
                <option>Urgent</option>
                <option>Emergency</option>
              </select>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Creating...' : 'Create Visit'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/front-office-dashboard')}>
              Cancel
            </button>
          </div>
        </form>
      </div>

      {createdVisitInfo && (
        <VisitCreatedModal
          title="Visit Created"
          subtitle={`${formatPatientName(createdVisitInfo.patient)} -- UHID: ${createdVisitInfo.patient.uhid}`}
          visit={createdVisitInfo.visit}
          onClose={() => router.push('/front-office-dashboard?visitCreated=1')}
        />
      )}
    </div>
  );
}
