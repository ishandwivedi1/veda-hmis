'use client';

import { useState, useEffect, useCallback, useRef, Fragment } from 'react';
import { formatPatientName } from '@/lib/patientName';
import {
  getTodayCollectionSummary,
  getReconciliationData,
  saveReconciliation,
  getCloseDayReadiness,
  closeDay,
  getDayClosingHistory,
  getDailyReport,
  reopenDay,
  getDayOpening,
  openDay,
  getRevenueByDepartmentToday,
  getUnclosedPastDays,
  getExpenseCategoriesActive,
  getExpensesForDate,
  getPettyCashTotal,
  addExpense,
  deleteExpense,
} from './actions';
import { addExpenseCategory } from '@/app/(main)/master-data/actions';
import { getApprovers } from '@/app/(main)/payments/actions';
import { getOpenQueueEntriesToday, bulkForceCloseQueueEntries } from '@/app/(main)/queue/actions';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import { uploadAttachment } from '@/lib/attachments';

const TABS = [
  { key: 'summary', label: "Today's Collection", icon: 'ti-chart-bar' },
  { key: 'pettycash', label: 'Petty Cash', icon: 'ti-cash-banknote' },
  { key: 'reconciliation', label: 'Reconciliation', icon: 'ti-calculator' },
  { key: 'close', label: 'Close Day', icon: 'ti-lock' },
  { key: 'report', label: 'Daily Report', icon: 'ti-file-text' },
  { key: 'history', label: 'History', icon: 'ti-history' },
];

const VARIANCE_REASONS = ['Change given error', 'Denomination counting error', 'Uncounted change', 'Recording error', 'Other'];

function fmt(n) {
  return `Rs.${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function CashManagementPage() {
  const [activeTab, setActiveTab] = useState('summary');
  const [summary, setSummary] = useState({ transactions: [], byMode: {}, total: 0, count: 0 });
  const [revenueByDept, setRevenueByDept] = useState({});
  const [reconRows, setReconRows] = useState([]);
  const [readiness, setReadiness] = useState(null);
  const [history, setHistory] = useState([]);
  const [approvers, setApprovers] = useState([]);
  const [closedToday, setClosedToday] = useState(false);
  const [opening, setOpening] = useState(null);
  const [openingBalance, setOpeningBalance] = useState('');
  const [openingRemarks, setOpeningRemarks] = useState('');
  const [todayClosingInfo, setTodayClosingInfo] = useState(null);
  const [openQueueEntries, setOpenQueueEntries] = useState([]);
  const [bulkCloseReason, setBulkCloseReason] = useState('');
  const [bulkClosing, setBulkClosing] = useState(false);
  const [unclosedPastDays, setUnclosedPastDays] = useState([]);
  const [closingPastDate, setClosingPastDate] = useState(null);
  const [pastSummary, setPastSummary] = useState(null);
  const [pastReconRows, setPastReconRows] = useState([]);
  const [pastReconEdits, setPastReconEdits] = useState({});
  const [pastReconApprover, setPastReconApprover] = useState('');
  const [pastCloseNotes, setPastCloseNotes] = useState('');
  const [pastLoading, setPastLoading] = useState(false);

  const [reconEdits, setReconEdits] = useState({});
  const [reconApprover, setReconApprover] = useState('');
  const [closeNotes, setCloseNotes] = useState('');
  const [reportDate, setReportDate] = useState(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }));
  const [report, setReport] = useState(null);
  const [reopenTarget, setReopenTarget] = useState(null);
  const [reopenReason, setReopenReason] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const [expenseCategories, setExpenseCategories] = useState([]);
  const [todayExpenses, setTodayExpenses] = useState([]);
  const [pettyCashTotal, setPettyCashTotal] = useState(0);
  const [newExpenseCategory, setNewExpenseCategory] = useState('');
  const [newExpenseAmount, setNewExpenseAmount] = useState('');
  const [newExpenseRemarks, setNewExpenseRemarks] = useState('');
  const [newExpenseBill, setNewExpenseBill] = useState(null);
  const [expenseSaving, setExpenseSaving] = useState(false);
  const [showAddCategory, setShowAddCategory] = useState(false);
  const [newCategoryName, setNewCategoryName] = useState('');
  const [expandedExpenseId, setExpandedExpenseId] = useState(null);
  const billInputRef = useRef(null);

  const refreshPettyCash = useCallback(async () => {
    const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
    const [cats, expenses, total] = await Promise.all([
      getExpenseCategoriesActive(),
      getExpensesForDate(today),
      getPettyCashTotal(today),
    ]);
    setExpenseCategories(cats);
    setTodayExpenses(expenses);
    setPettyCashTotal(total);
  }, []);

  useEffect(() => { refreshPettyCash(); }, [refreshPettyCash]);

  async function handleAddExpense() {
    setError(''); setSuccess('');
    if (!newExpenseCategory) { setError('Select an expense category.'); return; }
    if (!newExpenseAmount || parseFloat(newExpenseAmount) <= 0) { setError('Enter a valid amount.'); return; }
    setExpenseSaving(true);
    const result = await addExpense(newExpenseCategory, parseFloat(newExpenseAmount), newExpenseRemarks, '');
    if (result.error) { setExpenseSaving(false); setError(result.error); return; }

    if (newExpenseBill && result.expense) {
      const formData = new FormData();
      formData.append('file', newExpenseBill);
      formData.append('entityType', 'petty_cash_expense');
      formData.append('entityId', result.expense.id);
      const uploadResult = await uploadAttachment(formData);
      if (uploadResult.error) setError(`Expense saved, but the bill upload failed: ${uploadResult.error}`);
    }

    setExpenseSaving(false);
    setNewExpenseCategory(''); setNewExpenseAmount(''); setNewExpenseRemarks(''); setNewExpenseBill(null);
    if (billInputRef.current) billInputRef.current.value = '';
    setSuccess('Expense recorded.');
    refreshPettyCash();
    refreshReconciliation();
  }

  async function handleDeleteExpense(exp) {
    if (!window.confirm(`Delete this ${fmt(exp.amount)} expense?`)) return;
    setError(''); setSuccess('');
    const result = await deleteExpense(exp.id, exp.expense_date);
    if (result.error) { setError(result.error); return; }
    refreshPettyCash();
    refreshReconciliation();
  }

  async function handleAddCategory() {
    setError('');
    if (!newCategoryName.trim()) return;
    const result = await addExpenseCategory({ name: newCategoryName });
    if (result.error) { setError(result.error); return; }
    setNewCategoryName('');
    setShowAddCategory(false);
    refreshPettyCash();
  }

  const refresh = useCallback(async () => {
    // Was previously a sequential await-then-Promise.all -- the other
    // 5 fetches don't depend on the summary at all, only readiness
    // does, so there's no reason to make them wait behind it.
    const [
      summaryData, revenueByDeptData, historyData,
      openingData, openQueueData, unclosedPastDaysData,
    ] = await Promise.all([
      getTodayCollectionSummary(),
      getRevenueByDepartmentToday(),
      getDayClosingHistory(),
      getDayOpening(),
      getOpenQueueEntriesToday(),
      getUnclosedPastDays(),
    ]);
    const readinessData = await getCloseDayReadiness(undefined, summaryData);
    // readiness.alreadyClosed is the same day_closings check
    // isTodayClosed() used to make as a separate RPC round trip.
    const isClosed = readinessData.alreadyClosed;
    setSummary(summaryData);
    setRevenueByDept(revenueByDeptData);
    setReadiness(readinessData);
    setReconRows(readinessData.reconciliation); // already computed inside getCloseDayReadiness -- no need to fetch again
    setHistory(historyData);
    setClosedToday(isClosed);
    setOpening(openingData);
    setOpenQueueEntries(openQueueData);
    setUnclosedPastDays(unclosedPastDaysData);
    if (isClosed) {
      const todayStr = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
      setTodayClosingInfo(await getDailyReport(todayStr));
    } else {
      setTodayClosingInfo(null);
    }
  }, []);

  // Scoped refresh for the actual closing ritual -- saving one payment
  // mode's reconciliation (or adding/removing a petty cash expense,
  // which changes Cash's expected figure) doesn't change the
  // underlying transactions for the day at all, so there's no reason
  // to re-run the heavy payments+joins query, revenue-by-department,
  // 30-row closing history, day opening, open queue, and unclosed-past-
  // days checks every single time. Closing a day with 5 payment modes
  // used to mean 5 full-page-equivalent reloads back to back -- this
  // is the fix for that. Reuses the summary already in state (petty
  // cash total is always fetched fresh inside getReconciliationData
  // regardless, so Cash's expected figure still updates correctly).
  const refreshReconciliation = useCallback(async () => {
    if (!summary) { await refresh(); return; }
    const readinessData = await getCloseDayReadiness(undefined, summary);
    setReadiness(readinessData);
    setReconRows(readinessData.reconciliation);
    setClosedToday(readinessData.alreadyClosed);
  }, [summary, refresh]);

  useEffect(() => { refresh(); }, [refresh]);
  useEffect(() => { getApprovers().then(setApprovers); }, []);

  function updateReconField(mode, field, value) {
    setReconEdits((prev) => ({ ...prev, [mode]: { ...prev[mode], [field]: value } }));
  }

  async function handleSaveRecon(row) {
    setError(''); setSuccess('');
    const edit = reconEdits[row.mode] || {};
    const actual = edit.actual !== undefined ? parseFloat(edit.actual) : row.actual;
    const reason = edit.reason !== undefined ? edit.reason : row.reason;
    const variance = actual - row.expected;

    if (Math.abs(variance) > 0.01 && !reason) {
      setError(`A variance reason is required for ${row.mode} (variance: ${fmt(variance)}).`);
      return;
    }
    if (Math.abs(variance) > 0.01 && !reconApprover) {
      setError('Select a supervisor to approve this variance.');
      return;
    }

    const result = await saveReconciliation(row.mode, row.expected, actual, reason, Math.abs(variance) > 0.01 ? reconApprover : null);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${row.mode} reconciled.`);
    refreshReconciliation();
  }

  async function handleOpenDay() {
    setError(''); setSuccess('');
    const result = await openDay(parseFloat(openingBalance) || 0, openingRemarks);
    if (result.error) { setError(result.error); return; }
    setSuccess('Day opened.');
    setOpeningBalance(''); setOpeningRemarks('');
    refresh();
  }

  // Soft warning, not a hard block -- Close Day can still proceed with
  // patients left open in Doctor/Optometry queues. This just makes it a
  // deliberate choice with a reason on record, instead of those visits
  // silently rolling into tomorrow's queue view.
  async function handleBulkForceClose() {
    setError(''); setSuccess('');
    if (!bulkCloseReason.trim()) { setError('A reason is required to close these visits.'); return; }
    setBulkClosing(true);
    const ids = openQueueEntries.map((e) => e.id);
    const result = await bulkForceCloseQueueEntries(ids, bulkCloseReason);
    setBulkClosing(false);
    if (result.error) { setError(result.error); return; }
    setSuccess(`Closed ${result.count} visit(s).`);
    setBulkCloseReason('');
    refresh();
  }

  // ── CLOSE A PAST DAY -- self-contained, mirrors the main
  // Reconciliation/Close Day flow but scoped to a specific backdated
  // date instead of today, with its own state so it can't collide with
  // whatever's happening on today's tabs at the same time. ──
  async function openPastDayClosing(date) {
    setError(''); setSuccess('');
    setClosingPastDate(date);
    setPastReconEdits({});
    setPastCloseNotes('');
    // Fetched once per session and reused on every mode save below --
    // the underlying transactions for a past, already-finished day
    // never change mid-session, so there's no reason to re-run the
    // heavy payments+joins query after every single save (same fix as
    // the main today's-reconciliation flow above).
    const summaryData = await getTodayCollectionSummary(date);
    setPastSummary(summaryData);
    setPastReconRows(await getReconciliationData(date, summaryData));
  }

  function updatePastReconField(mode, field, value) {
    setPastReconEdits((prev) => ({ ...prev, [mode]: { ...prev[mode], [field]: value } }));
  }

  async function handleSavePastRecon(row) {
    setError(''); setSuccess('');
    const edit = pastReconEdits[row.mode] || {};
    const actual = edit.actual !== undefined ? parseFloat(edit.actual) : row.actual;
    const reason = edit.reason !== undefined ? edit.reason : row.reason;
    const variance = actual - row.expected;

    if (Math.abs(variance) > 0.01 && !reason) {
      setError(`A variance reason is required for ${row.mode} (variance: ${fmt(variance)}).`);
      return;
    }
    if (Math.abs(variance) > 0.01 && !pastReconApprover) {
      setError('Select a supervisor to approve this variance.');
      return;
    }

    const result = await saveReconciliation(row.mode, row.expected, actual, reason, Math.abs(variance) > 0.01 ? pastReconApprover : null, closingPastDate);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${row.mode} reconciled for ${closingPastDate}.`);
    setPastReconRows(await getReconciliationData(closingPastDate, pastSummary));
  }

  async function handleClosePastDay() {
    setError(''); setSuccess('');
    const allSaved = pastReconRows.every((r) => r.saved);
    if (!allSaved) { setError('Complete reconciliation for every payment mode before closing this day.'); return; }
    setPastLoading(true);
    const result = await closeDay(pastCloseNotes, closingPastDate);
    setPastLoading(false);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${closingPastDate} closed successfully.`);
    setClosingPastDate(null);
    refresh();
  }

  async function handleCloseDay() {
    setError(''); setSuccess('');
    if (!readiness?.reconciliationComplete) { setError('Complete reconciliation for every payment mode before closing.'); return; }
    setLoading(true);
    const result = await closeDay(closeNotes);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setSuccess('Day closed successfully. Daily report generated.');
    refresh();
    setActiveTab('report');
    loadReport(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }));
  }

  async function loadReport(date) {
    setReport(await getDailyReport(date));
  }

  useEffect(() => { if (activeTab === 'report') loadReport(reportDate); }, [activeTab, reportDate]);

  async function handleReopen() {
    if (!reopenReason.trim()) { setError('A reason is required to reopen.'); return; }
    setError('');
    const result = await reopenDay(reopenTarget, reopenReason);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${reopenTarget} reopened.`);
    setReopenTarget(null);
    setReopenReason('');
    refresh();
  }

  return (
    <div>
      <div style={{ borderRadius: 12, padding: '14px 18px', marginBottom: 16, color: '#fff', background: closedToday ? 'linear-gradient(135deg,#303a42,#1c242b)' : opening ? 'linear-gradient(135deg,#166534,#157a4f)' : 'linear-gradient(135deg,#92400e,#a15c00)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ width: 10, height: 10, borderRadius: '50%', background: closedToday ? '#97a0aa' : opening ? '#4ade80' : '#fbbf24', boxShadow: closedToday ? 'none' : `0 0 8px ${opening ? '#4ade80' : '#fbbf24'}` }}></div>
          <div>
            <div style={{ fontWeight: 700 }}>
              {closedToday ? `Closed at ${new Date(todayClosingInfo?.closing?.closed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}` : opening ? `Opened at ${new Date(opening.opened_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} by ${opening.profiles?.full_name || '--'}` : 'Day not opened yet'}
            </div>
            <div style={{ fontSize: 12, opacity: .85 }}>{new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })}</div>
          </div>
          <div style={{ marginLeft: 'auto', fontSize: 13 }}>{fmt(summary.total)} collected today ({summary.count} transactions)</div>
        </div>
        {!opening && !closedToday && (
          <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid rgba(255,255,255,.25)', display: 'flex', gap: 8, alignItems: 'flex-end', flexWrap: 'wrap' }}>
            <div>
              <label style={{ fontSize: 10, opacity: .85, display: 'block', marginBottom: 3 }}>Opening cash balance (Rs.)</label>
              <input type="number" value={openingBalance} onChange={(e) => setOpeningBalance(e.target.value)} placeholder="0.00" style={{ padding: '6px 10px', borderRadius: 6, border: 'none', width: 140 }} />
            </div>
            <div style={{ flex: 1, minWidth: 160 }}>
              <label style={{ fontSize: 10, opacity: .85, display: 'block', marginBottom: 3 }}>Remarks</label>
              <input value={openingRemarks} onChange={(e) => setOpeningRemarks(e.target.value)} placeholder="Optional..." style={{ padding: '6px 10px', borderRadius: 6, border: 'none', width: '100%' }} />
            </div>
            <button className="btn" style={{ background: '#fff', color: 'var(--amber)', fontWeight: 700 }} onClick={handleOpenDay}>
              <i className="ti ti-unlock"></i> Open Day
            </button>
          </div>
        )}
      </div>

      <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
        {TABS.map((t) => (
          <button key={t.key} className={activeTab === t.key ? 'btn btn-primary' : 'btn'} onClick={() => { setActiveTab(t.key); setError(''); setSuccess(''); }}>
            <i className={`ti ${t.icon}`}></i> {t.label}
          </button>
        ))}
      </div>

      {error && <div className="msg-err">{error}</div>}
      {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

      {activeTab === 'summary' && (
        <div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 16 }}>
            <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Collected</div>
              <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(summary.total)}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{summary.count} transactions</div>
            </div>
            {['Cash', 'UPI', 'Card'].map((m) => (
              <div key={m} className="card" style={{ borderTop: '3px solid var(--blue)' }}>
                <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>{m}</div>
                <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(summary.byMode[m] || 0)}</div>
              </div>
            ))}
          </div>

          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-bar" style={{ color: 'var(--amber)' }}></i> Revenue by Department -- Today
            </div>
            {Object.keys(revenueByDept).length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices yet today.</div>}
            {Object.entries(revenueByDept).sort((a, b) => b[1] - a[1]).map(([dept, amount]) => {
              const max = Math.max(...Object.values(revenueByDept));
              return (
                <div key={dept} style={{ marginBottom: 10 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                    <span>{dept}</span><span style={{ fontWeight: 600 }}>{fmt(amount)}</span>
                  </div>
                  <div style={{ height: 8, background: 'var(--g100)', borderRadius: 4 }}>
                    <div style={{ width: `${max ? (amount / max) * 100 : 0}%`, height: '100%', background: 'var(--amber)', borderRadius: 4 }}></div>
                  </div>
                </div>
              );
            })}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt" style={{ color: 'var(--green)' }}></i> Transactions Today</div>
            <table className="tbl">
              <thead><tr><th>Receipt #</th><th>Time</th><th>Patient</th><th>Mode(s)</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {summary.transactions.map((p) => {
                  const isNonCash = p.payment_type === 'advance_adjustment' || p.payment_type === 'credit_note';
                  return (
                    <tr key={p.id} style={isNonCash ? { opacity: 0.65 } : undefined}>
                      <td style={{ fontFamily: 'monospace' }}>{p.receipt_number}</td>
                      <td>{new Date(p.collected_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                      <td>{formatPatientName(p.patients)}</td>
                      <td>
                        {(p.payment_modes || []).map((m) => m.mode).join('+')}
                        {isNonCash && <span className="badge b-gray" style={{ fontSize: 9, marginLeft: 4 }}>{p.payment_type === 'credit_note' ? 'Credit note -- no cash' : 'Adjustment -- no new cash'}</span>}
                      </td>
                      <td style={{ textAlign: 'right', fontWeight: 600, color: p.payment_type === 'refund' ? 'var(--red)' : 'var(--g800)' }}>
                        {p.payment_type === 'refund' ? '-' : ''}{fmt(p.total_amount)}
                      </td>
                    </tr>
                  );
                })}
                {summary.transactions.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No transactions yet today.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {activeTab === 'pettycash' && (
        <div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 16, marginBottom: 16 }}>
            <div className="card" style={{ borderTop: '3px solid var(--red)' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today's Petty Cash Spend</div>
              <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(pettyCashTotal)}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{todayExpenses.length} entries</div>
            </div>
            <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Net Cash Expected</div>
              <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt((summary.byMode['Cash'] || 0) - pettyCashTotal)}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>Cash collected minus petty cash</div>
            </div>
          </div>

          {!opening && (
            <div className="msg-err" style={{ marginBottom: 14 }}><i className="ti ti-alert-triangle"></i> Today's cash day hasn't been opened yet. Open it from the "Today's Collection" tab before recording expenses.</div>
          )}
          {closedToday && (
            <div className="msg-err" style={{ marginBottom: 14 }}><i className="ti ti-lock"></i> Today is already closed -- petty cash entries are locked. See the Daily Report tab.</div>
          )}

          {!closedToday && opening && (
            <div className="card" style={{ marginBottom: 16 }}>
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-plus" style={{ color: 'var(--green)' }}></i> Record an Expense</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1.6fr 0.8fr 1.6fr', gap: 10, marginBottom: 10 }}>
                <select className="fi" value={newExpenseCategory} onChange={(e) => setNewExpenseCategory(e.target.value)}>
                  <option value="">-- Category --</option>
                  {expenseCategories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
                <input type="number" className="fi" placeholder="Amount" value={newExpenseAmount} onChange={(e) => setNewExpenseAmount(e.target.value)} />
                <input type="text" className="fi" placeholder="Remarks (optional)" value={newExpenseRemarks} onChange={(e) => setNewExpenseRemarks(e.target.value)} />
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <label className="btn" style={{ cursor: 'pointer', marginBottom: 0 }}>
                  <i className="ti ti-paperclip"></i> {newExpenseBill ? newExpenseBill.name : 'Attach bill (optional)'}
                  <input ref={billInputRef} type="file" accept="application/pdf,image/jpeg,image/png,image/jpg" onChange={(e) => setNewExpenseBill(e.target.files?.[0] || null)} style={{ display: 'none' }} />
                </label>
                {newExpenseBill && (
                  <button className="btn" style={{ padding: '3px 9px', fontSize: 11 }} onClick={() => { setNewExpenseBill(null); if (billInputRef.current) billInputRef.current.value = ''; }}>
                    <i className="ti ti-x"></i>
                  </button>
                )}
                <span style={{ flex: 1 }}></span>
                <button className="btn btn-primary" disabled={expenseSaving} onClick={handleAddExpense}>{expenseSaving ? 'Saving...' : 'Add Expense'}</button>
              </div>

              {!showAddCategory && (
                <div style={{ marginTop: 10 }}>
                  <button className="btn btn-sm" onClick={() => setShowAddCategory(true)}><i className="ti ti-plus"></i> New category</button>
                </div>
              )}
              {showAddCategory && (
                <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
                  <input type="text" className="fi fi-sm" style={{ maxWidth: 220 }} placeholder="Category name" value={newCategoryName} onChange={(e) => setNewCategoryName(e.target.value)} />
                  <button className="btn btn-sm btn-primary" onClick={handleAddCategory}>Save</button>
                  <button className="btn btn-sm" onClick={() => { setShowAddCategory(false); setNewCategoryName(''); }}>Cancel</button>
                </div>
              )}
            </div>
          )}

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i> Today's Expenses</div>
            <table className="tbl">
              <thead><tr><th>Time</th><th>Category</th><th>Remarks</th><th>Entered By</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
              <tbody>
                {todayExpenses.map((exp) => (
                  <Fragment key={exp.id}>
                    <tr>
                      <td>{new Date(exp.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                      <td>{exp.master_expense_categories?.name}</td>
                      <td>{exp.paid_to || '--'}</td>
                      <td>{exp.profiles?.full_name || 'Staff'}</td>
                      <td style={{ textAlign: 'right', fontWeight: 600 }}>{fmt(exp.amount)}</td>
                      <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                        <button className="btn" style={{ padding: '3px 9px', fontSize: 11 }} onClick={() => setExpandedExpenseId(expandedExpenseId === exp.id ? null : exp.id)}>
                          <i className="ti ti-paperclip"></i>
                        </button>
                        {!closedToday && (
                          <button className="btn" style={{ padding: '3px 9px', fontSize: 11, marginLeft: 4 }} onClick={() => handleDeleteExpense(exp)}>
                            <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i>
                          </button>
                        )}
                      </td>
                    </tr>
                    {expandedExpenseId === exp.id && (
                      <tr>
                        <td colSpan={6} style={{ background: 'var(--g50)' }}>
                          <AttachmentUploader entityType="petty_cash_expense" entityId={exp.id} title="Bill / Receipt" />
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
                {todayExpenses.length === 0 && (
                  <tr><td colSpan={6} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No petty cash expenses recorded today.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {activeTab === 'reconciliation' && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-calculator" style={{ color: 'var(--amber)' }}></i> Cash Reconciliation</div>
          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 14 }}>
            <i className="ti ti-info-circle"></i> Enter the actual counted amount for each mode. The system computes variance automatically -- a reason and supervisor approval are required whenever actual differs from expected.
          </div>
          {closedToday && (
            <div className="msg-err" style={{ marginBottom: 14 }}><i className="ti ti-lock"></i> Today is already closed -- reconciliation is read-only.</div>
          )}

          <div style={{ display: 'flex', padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, marginBottom: 6, fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
            <span style={{ minWidth: 140 }}>Mode</span>
            <span style={{ minWidth: 130, textAlign: 'right' }}>Expected</span>
            <span style={{ flex: 1, textAlign: 'center' }}>Actual</span>
            <span style={{ minWidth: 130, textAlign: 'right' }}>Variance</span>
            <span style={{ minWidth: 90 }}></span>
          </div>

          {reconRows.map((row) => {
            const editedActual = reconEdits[row.mode]?.actual !== undefined ? reconEdits[row.mode].actual : row.actual;
            const variance = parseFloat(editedActual || 0) - row.expected;
            const hasVariance = Math.abs(variance) > 0.01;
            return (
              <div key={row.mode} style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', background: hasVariance ? 'var(--amber-lt)' : 'transparent', borderRadius: 8, marginBottom: 6 }}>
                <div style={{ display: 'flex', alignItems: 'center' }}>
                  <span style={{ minWidth: 140, fontWeight: 600, fontSize: 13 }}>{row.mode}</span>
                  <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: 'var(--green)' }}>{fmt(row.expected)}</span>
                  <span style={{ flex: 1, textAlign: 'center' }}>
                    <input type="number" className="fi fi-sm" style={{ maxWidth: 140, textAlign: 'right', display: 'inline-block' }} value={editedActual} disabled={closedToday}
                      onChange={(e) => updateReconField(row.mode, 'actual', e.target.value)} />
                  </span>
                  <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: hasVariance ? 'var(--red)' : 'var(--g400)' }}>
                    {hasVariance ? (variance > 0 ? '+' : '') + fmt(variance) : fmt(0)}
                  </span>
                  <span style={{ minWidth: 90, textAlign: 'right' }}>
                    {!closedToday && <button className="btn btn-sm btn-primary" onClick={() => handleSaveRecon(row)}>Save</button>}
                    {row.saved && <span className="badge b-green" style={{ marginLeft: 6 }}>Saved</span>}
                  </span>
                </div>
                {hasVariance && !closedToday && (
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginTop: 8 }}>
                    <select className="fi fi-sm" value={reconEdits[row.mode]?.reason !== undefined ? reconEdits[row.mode].reason : row.reason} onChange={(e) => updateReconField(row.mode, 'reason', e.target.value)}>
                      <option value="">-- Variance reason --</option>
                      {VARIANCE_REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                    </select>
                    <select className="fi fi-sm" value={reconApprover} onChange={(e) => setReconApprover(e.target.value)}>
                      <option value="">-- Approved by --</option>
                      {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                    </select>
                  </div>
                )}
              </div>
            );
          })}
          {reconRows.length === 0 && <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No collections yet today -- nothing to reconcile.</div>}
        </div>
      )}

      {activeTab === 'close' && (
        <>
        {unclosedPastDays.length > 0 && (
          <div className="card" style={{ marginBottom: 16, border: '1.5px solid var(--red)' }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> {unclosedPastDays.length} day(s) were opened but never closed
            </div>
            <div className="msg-err" style={{ marginBottom: 12 }}>
              <i className="ti ti-lock"></i> A new day can&apos;t be opened until these are resolved. Close them here, oldest first.
            </div>

            {!closingPastDate ? (
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                {unclosedPastDays.map((d) => (
                  <button key={d} className="btn" style={{ borderColor: 'var(--red)', color: 'var(--red)' }} onClick={() => openPastDayClosing(d)}>
                    <i className="ti ti-calendar-exclamation"></i> Close {d}
                  </button>
                ))}
              </div>
            ) : (
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                  <strong style={{ fontSize: 14 }}>Closing {closingPastDate}</strong>
                  <button className="btn btn-sm" onClick={() => setClosingPastDate(null)}>Back to list</button>
                </div>

                <div style={{ display: 'flex', padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, marginBottom: 6, fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
                  <span style={{ minWidth: 140 }}>Mode</span>
                  <span style={{ minWidth: 130, textAlign: 'right' }}>Expected</span>
                  <span style={{ flex: 1, textAlign: 'center' }}>Actual</span>
                  <span style={{ minWidth: 130, textAlign: 'right' }}>Variance</span>
                  <span style={{ minWidth: 90 }}></span>
                </div>
                {pastReconRows.map((row) => {
                  const editedActual = pastReconEdits[row.mode]?.actual !== undefined ? pastReconEdits[row.mode].actual : row.actual;
                  const variance = parseFloat(editedActual || 0) - row.expected;
                  const hasVariance = Math.abs(variance) > 0.01;
                  return (
                    <div key={row.mode} style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', background: hasVariance ? 'var(--amber-lt)' : 'transparent', borderRadius: 8, marginBottom: 6 }}>
                      <div style={{ display: 'flex', alignItems: 'center' }}>
                        <span style={{ minWidth: 140, fontWeight: 600, fontSize: 13 }}>{row.mode}</span>
                        <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: 'var(--green)' }}>{fmt(row.expected)}</span>
                        <span style={{ flex: 1, textAlign: 'center' }}>
                          <input type="number" className="fi fi-sm" style={{ maxWidth: 140, textAlign: 'right', display: 'inline-block' }} value={editedActual}
                            onChange={(e) => updatePastReconField(row.mode, 'actual', e.target.value)} />
                        </span>
                        <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: hasVariance ? 'var(--red)' : 'var(--g400)' }}>
                          {hasVariance ? (variance > 0 ? '+' : '') + fmt(variance) : fmt(0)}
                        </span>
                        <span style={{ minWidth: 90, textAlign: 'right' }}>
                          <button className="btn btn-sm btn-primary" onClick={() => handleSavePastRecon(row)}>Save</button>
                          {row.saved && <span className="badge b-green" style={{ marginLeft: 6 }}>Saved</span>}
                        </span>
                      </div>
                      {hasVariance && (
                        <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                          <input className="fi fi-sm" placeholder="Variance reason" value={pastReconEdits[row.mode]?.reason !== undefined ? pastReconEdits[row.mode].reason : row.reason}
                            onChange={(e) => updatePastReconField(row.mode, 'reason', e.target.value)} />
                          <select className="fi fi-sm" value={pastReconApprover} onChange={(e) => setPastReconApprover(e.target.value)}>
                            <option value="">-- Approving supervisor --</option>
                            {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                          </select>
                        </div>
                      )}
                    </div>
                  );
                })}
                {pastReconRows.length === 0 && <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No collections recorded for this date -- nothing to reconcile.</div>}

                <label className="flbl" style={{ marginTop: 14 }}>Closing notes</label>
                <textarea className="fi" rows={2} style={{ marginBottom: 10 }} value={pastCloseNotes} onChange={(e) => setPastCloseNotes(e.target.value)} placeholder="e.g. Closed late -- internet outage on this date" />
                <button className="btn btn-danger" onClick={handleClosePastDay} disabled={pastLoading || (pastReconRows.length > 0 && !pastReconRows.every((r) => r.saved))}>
                  <i className="ti ti-lock"></i> {pastLoading ? 'Closing...' : `Close ${closingPastDate}`}
                </button>
              </div>
            )}
          </div>
        )}

        <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 20 }}>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-lock" style={{ color: 'var(--red)' }}></i> Close Day</div>
            {closedToday ? (
              <div className="msg-success"><i className="ti ti-circle-check"></i> Today is already closed. See the Daily Report tab.</div>
            ) : (
              <>
                <div className="msg-err" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', border: 'none' }}>
                  <i className="ti ti-alert-triangle"></i> Once closed, no new visits, invoices, or payments can be created for today until it's reopened.
                </div>
                <label className="flbl">Closing notes</label>
                <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={closeNotes} onChange={(e) => setCloseNotes(e.target.value)} placeholder="Optional..." />
                <button className="btn btn-danger" onClick={handleCloseDay} disabled={loading || !readiness?.reconciliationComplete}>
                  <i className="ti ti-lock"></i> {loading ? 'Closing...' : 'Close Day and Generate Report'}
                </button>
              </>
            )}
          </div>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-checklist" style={{ color: 'var(--green)' }}></i> Pre-close Checklist</div>
            <div style={{ fontSize: 13, lineHeight: 2.2 }}>
              <div><i className={`ti ${opening ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: opening ? 'var(--green)' : 'var(--amber)', marginRight: 6 }}></i>
                Day opened{opening ? ` at ${new Date(opening.opened_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}` : ' -- required before any payment can be collected today'}
              </div>
              <div><i className={`ti ${readiness?.reconciliationComplete ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: readiness?.reconciliationComplete ? 'var(--green)' : 'var(--red)', marginRight: 6 }}></i>
                Reconciliation complete for all payment modes
              </div>
              <div><i className={`ti ${!closedToday ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: !closedToday ? 'var(--green)' : 'var(--red)', marginRight: 6 }}></i>
                Day not already closed
              </div>
            </div>
          </div>

          {openQueueEntries.length > 0 && (
            <div className="card" style={{ gridColumn: '1 / -1' }}>
              <div className="card-title" style={{ marginBottom: 10 }}>
                <i className="ti ti-alert-triangle" style={{ color: 'var(--amber)' }}></i> {openQueueEntries.length} visit(s) still open in Doctor/Optometry queues
              </div>
              <div className="msg-info" style={{ marginBottom: 10 }}>
                <i className="ti ti-info-circle"></i> These won&apos;t block closing the day, but if left as-is they&apos;ll keep showing as pending tomorrow. Close them now with a shared reason, or leave them and resolve individually later from the Queue.
              </div>
              <table className="tbl" style={{ marginBottom: 12 }}>
                <thead><tr><th>Patient</th><th>Dept</th><th>Token</th><th>Status</th><th>Since</th></tr></thead>
                <tbody>
                  {openQueueEntries.map((e) => (
                    <tr key={e.id}>
                      <td>{formatPatientName(e.visits?.patients)} <span style={{ color: 'var(--g400)', fontSize: 11 }}>({e.visits?.patients?.uhid})</span></td>
                      <td>{e.department}</td>
                      <td>{e.token}</td>
                      <td>{e.status}</td>
                      <td>{new Date(e.issued_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <label className="flbl">Reason (applied to all {openQueueEntries.length} visits above) *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={bulkCloseReason} onChange={(e) => setBulkCloseReason(e.target.value)} placeholder="e.g. End of day -- unresolved at closing time" />
                <button className="btn" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleBulkForceClose} disabled={bulkClosing}>
                  {bulkClosing ? 'Closing...' : `Close All ${openQueueEntries.length}`}
                </button>
              </div>
            </div>
          )}
        </div>
        </>
      )}

      {activeTab === 'report' && (
        <div>
          <div className="card" style={{ marginBottom: 16 }}>
            <label className="flbl">Report date</label>
            <input type="date" className="fi" style={{ maxWidth: 200 }} value={reportDate} onChange={(e) => setReportDate(e.target.value)} />
          </div>
          {!report?.closing ? (
            <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No closed day on record for this date.</div>
          ) : (
            <>
              <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#1e4e8c)', color: '#fff', borderRadius: 12, padding: '20px 24px', marginBottom: 16 }}>
                <div style={{ fontSize: 18, fontWeight: 700 }}>VEDA EYE HOSPITAL</div>
                <div style={{ fontSize: 12, opacity: .8 }}>Haridwar, Uttarakhand</div>
                <div style={{ fontSize: 13, fontWeight: 700, marginTop: 10, borderTop: '1px solid rgba(255,255,255,.2)', paddingTop: 10 }}>
                  DAILY CASH CLOSING REPORT<br />
                  Date: {report.closing.closing_date}<br />
                  Closed by: {report.closing.profiles?.full_name || '--'} at {new Date(report.closing.closed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata' })}
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt" style={{ color: 'var(--blue)' }}></i> Billed Items</div>
                  {Object.keys(report.billedItems.byMode).length === 0 ? (
                    <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing collected against invoices today.</div>
                  ) : (
                    <>
                      {Object.entries(report.billedItems.byMode).map(([mode, amt]) => (
                        <div key={mode} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                          <span>{mode}</span><span>{fmt(amt)}</span>
                        </div>
                      ))}
                      <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0 0', fontSize: 13, fontWeight: 700 }}>
                        <span>Total ({report.billedItems.count} receipt{report.billedItems.count === 1 ? '' : 's'})</span>
                        <span style={{ color: 'var(--blue)' }}>{fmt(report.billedItems.total)}</span>
                      </div>
                    </>
                  )}
                </div>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-piggy-bank" style={{ color: 'var(--purple)' }}></i> Advances</div>
                  {Object.keys(report.advances.byMode).length === 0 ? (
                    <div style={{ fontSize: 12, color: 'var(--g400)' }}>No advances collected today.</div>
                  ) : (
                    <>
                      {Object.entries(report.advances.byMode).map(([mode, amt]) => (
                        <div key={mode} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                          <span>{mode}</span><span>{fmt(amt)}</span>
                        </div>
                      ))}
                      <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0 0', fontSize: 13, fontWeight: 700 }}>
                        <span>Total ({report.advances.count} receipt{report.advances.count === 1 ? '' : 's'})</span>
                        <span style={{ color: 'var(--purple)' }}>{fmt(report.advances.total)}</span>
                      </div>
                    </>
                  )}
                </div>
              </div>

              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-cash-banknote" style={{ color: 'var(--green)' }}></i> Payment Mode Summary</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                  Billed Items + Advances{report.refunds.total !== 0 ? ' - Refunds' : ''}, by mode -- the actual cash movement for the day.
                </div>
                {Object.keys(report.modeSummary.byMode).length === 0 ? (
                  <div style={{ fontSize: 12, color: 'var(--g400)' }}>No payments recorded today.</div>
                ) : (
                  <>
                    {Object.entries(report.modeSummary.byMode).map(([mode, amt]) => (
                      <div key={mode} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                        <span>{mode}</span><span style={{ fontWeight: 600 }}>{fmt(amt)}</span>
                      </div>
                    ))}
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0 0', fontSize: 14, fontWeight: 700 }}>
                      <span>Grand Total</span>
                      <span style={{ color: 'var(--green)' }}>{fmt(report.modeSummary.total)}</span>
                    </div>
                  </>
                )}
                {report.refunds.total !== 0 && (
                  <div style={{ marginTop: 10, paddingTop: 10, borderTop: '1px dashed var(--g200)' }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--red)', marginBottom: 4 }}>Refunds paid out (already netted above)</div>
                    {Object.entries(report.refunds.byMode).map(([mode, amt]) => (
                      <div key={mode} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12, color: 'var(--red)' }}>
                        <span>{mode}</span><span>{fmt(amt)}</span>
                      </div>
                    ))}
                  </div>
                )}
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}>Reconciliation Summary</div>
                  {report.reconciliation.map((r) => (
                    <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <span>{r.mode}</span>
                      <span style={{ fontWeight: 600, color: Math.abs(r.variance) > 0.01 ? 'var(--red)' : 'var(--green)' }}>
                        {fmt(r.actual)}{Math.abs(r.variance) > 0.01 ? ` (var: ${r.variance > 0 ? '+' : ''}${fmt(r.variance)})` : ''}
                      </span>
                    </div>
                  ))}
                </div>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}>Day Totals</div>
                  <div style={{ fontSize: 13, lineHeight: 2 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total Revenue (billed)</span><strong>{fmt(report.closing.total_revenue)}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total Collected</span><strong style={{ color: 'var(--green)' }}>{fmt(report.closing.total_collected)}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Outstanding</span><strong style={{ color: 'var(--amber)' }}>{fmt(report.closing.total_outstanding)}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Petty Cash Spent</span><strong style={{ color: 'var(--red)' }}>{fmt(report.closing.total_petty_cash_expenses)}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Invoices</span><strong>{report.closing.total_invoices}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Visits</span><strong>{report.closing.total_visits}</strong></div>
                  </div>
                </div>
              </div>

              {report.expenses.length > 0 && (
                <div className="card" style={{ marginTop: 16 }}>
                  <div className="card-title" style={{ marginBottom: 10 }}>Petty Cash Expenses</div>
                  <table className="tbl">
                    <thead><tr><th>Category</th><th>Remarks</th><th>Entered By</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
                    <tbody>
                      {report.expenses.map((exp) => (
                        <tr key={exp.id}>
                          <td>{exp.master_expense_categories?.name}</td>
                          <td>{exp.paid_to || '--'}</td>
                          <td>{exp.profiles?.full_name || 'Staff'}</td>
                          <td style={{ textAlign: 'right', fontWeight: 600 }}>{fmt(exp.amount)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          )}
        </div>
      )}

      {activeTab === 'history' && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Closing History</div>
          <table className="tbl">
            <thead><tr><th>Date</th><th>Closed By</th><th>Revenue</th><th>Collected</th><th>Outstanding</th><th></th></tr></thead>
            <tbody>
              {history.map((h) => (
                <tr key={h.id}>
                  <td style={{ fontFamily: 'monospace' }}>{h.closing_date}</td>
                  <td>{h.profiles?.full_name || '--'}</td>
                  <td>{fmt(h.total_revenue)}</td>
                  <td>{fmt(h.total_collected)}</td>
                  <td>{fmt(h.total_outstanding)}</td>
                  <td>
                    {reopenTarget === h.closing_date ? (
                      <div style={{ display: 'flex', gap: 4 }}>
                        <input className="fi fi-sm" placeholder="Reason" value={reopenReason} onChange={(e) => setReopenReason(e.target.value)} style={{ width: 140 }} />
                        <button className="btn btn-sm btn-danger" onClick={handleReopen}>Confirm</button>
                        <button className="btn btn-sm" onClick={() => setReopenTarget(null)}>Cancel</button>
                      </div>
                    ) : (
                      <button className="btn btn-sm" onClick={() => { setReopenTarget(h.closing_date); setReopenReason(''); }}>
                        <i className="ti ti-lock-open"></i> Reopen
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {history.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No closed days yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
