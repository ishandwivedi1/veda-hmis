#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# Writes the Petty Cash feature files, then commits and pushes.
# Apply the DB migration separately (see instructions below) BEFORE
# running this, or the app will error on the new tables/column.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/cash-management"
cat > "app/(main)/cash-management/page.js" << 'FILEEOF_page_js'
'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import {
  getTodayCollectionSummary,
  getReconciliationData,
  saveReconciliation,
  getCloseDayReadiness,
  closeDay,
  getDayClosingHistory,
  getDailyReport,
  reopenDay,
  isTodayClosed,
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
  const [newExpensePaidTo, setNewExpensePaidTo] = useState('');
  const [newExpenseNote, setNewExpenseNote] = useState('');
  const [expenseSaving, setExpenseSaving] = useState(false);
  const [showAddCategory, setShowAddCategory] = useState(false);
  const [newCategoryName, setNewCategoryName] = useState('');
  const [expandedExpenseId, setExpandedExpenseId] = useState(null);

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
    const result = await addExpense(newExpenseCategory, parseFloat(newExpenseAmount), newExpensePaidTo, newExpenseNote);
    setExpenseSaving(false);
    if (result.error) { setError(result.error); return; }
    setNewExpenseCategory(''); setNewExpenseAmount(''); setNewExpensePaidTo(''); setNewExpenseNote('');
    setSuccess('Expense recorded.');
    refreshPettyCash();
    refresh();
  }

  async function handleDeleteExpense(exp) {
    if (!window.confirm(`Delete this ${fmt(exp.amount)} expense?`)) return;
    setError(''); setSuccess('');
    const result = await deleteExpense(exp.id, exp.expense_date);
    if (result.error) { setError(result.error); return; }
    refreshPettyCash();
    refresh();
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
    const [
      summaryData, revenueByDeptData, readinessData, historyData,
      isClosed, openingData, openQueueData, unclosedPastDaysData,
    ] = await Promise.all([
      getTodayCollectionSummary(),
      getRevenueByDepartmentToday(),
      getCloseDayReadiness(),
      getDayClosingHistory(),
      isTodayClosed(),
      getDayOpening(),
      getOpenQueueEntriesToday(),
      getUnclosedPastDays(),
    ]);
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
    refresh();
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
    setPastReconRows(await getReconciliationData(date));
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
    setPastReconRows(await getReconciliationData(closingPastDate));
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
                {summary.transactions.map((p) => (
                  <tr key={p.id}>
                    <td style={{ fontFamily: 'monospace' }}>{p.receipt_number}</td>
                    <td>{new Date(p.collected_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    <td>{p.patients?.first_name} {p.patients?.last_name}</td>
                    <td>{(p.payment_modes || []).map((m) => m.mode).join('+')}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600, color: p.payment_type === 'refund' ? 'var(--red)' : 'var(--g800)' }}>
                      {p.payment_type === 'refund' ? '-' : ''}{fmt(p.total_amount)}
                    </td>
                  </tr>
                ))}
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
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 140px 1fr', gap: 10, marginBottom: 10 }}>
                <select className="fi" value={newExpenseCategory} onChange={(e) => setNewExpenseCategory(e.target.value)}>
                  <option value="">-- Category --</option>
                  {expenseCategories.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
                <input type="number" className="fi" placeholder="Amount" value={newExpenseAmount} onChange={(e) => setNewExpenseAmount(e.target.value)} />
                <input type="text" className="fi" placeholder="Paid to (optional)" value={newExpensePaidTo} onChange={(e) => setNewExpensePaidTo(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 10 }}>
                <input type="text" className="fi" style={{ flex: 1 }} placeholder="Note (optional)" value={newExpenseNote} onChange={(e) => setNewExpenseNote(e.target.value)} />
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
              <thead><tr><th>Time</th><th>Category</th><th>Paid To</th><th>Note</th><th>Entered By</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
              <tbody>
                {todayExpenses.map((exp) => (
                  <Fragment key={exp.id}>
                    <tr>
                      <td>{new Date(exp.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                      <td>{exp.master_expense_categories?.name}</td>
                      <td>{exp.paid_to || '--'}</td>
                      <td>{exp.note || '--'}</td>
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
                        <td colSpan={7} style={{ background: 'var(--g50)' }}>
                          <AttachmentUploader entityType="petty_cash_expense" entityId={exp.id} title="Receipt" />
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
                {todayExpenses.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No petty cash expenses recorded today.</td></tr>
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
                      <td>{e.visits?.patients?.first_name} {e.visits?.patients?.last_name} <span style={{ color: 'var(--g400)', fontSize: 11 }}>({e.visits?.patients?.uhid})</span></td>
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
                    <thead><tr><th>Category</th><th>Paid To</th><th>Note</th><th>Entered By</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
                    <tbody>
                      {report.expenses.map((exp) => (
                        <tr key={exp.id}>
                          <td>{exp.master_expense_categories?.name}</td>
                          <td>{exp.paid_to || '--'}</td>
                          <td>{exp.note || '--'}</td>
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


FILEEOF_page_js

mkdir -p "app/(main)/cash-management"
cat > "app/(main)/cash-management/actions.js" << 'FILEEOF_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

// A plain date string compared against a timestamptz column is
// interpreted at UTC midnight by Postgres, not IST midnight -- that
// mismatch is exactly what made the readiness check disagree with
// close_day() (which correctly uses the ist_date() helper). Building
// explicit +05:30 boundaries makes the two agree.
function istDayBoundsUTC(dateStr) {
  const d = dateStr || todayIST();
  return {
    dateStr: d,
    startUTC: new Date(`${d}T00:00:00+05:30`).toISOString(),
    endUTC: new Date(`${d}T23:59:59.999+05:30`).toISOString(),
  };
}

// ── PETTY CASH -- day-to-day hospital cash outgoings (stationery,
// transport, refreshments, minor repairs). Entered by any staff on a
// day that's open; no approval step. Folds into Cash reconciliation
// and Close Day so the drawer count ties out. ──
export async function getExpenseCategoriesActive() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_expense_categories').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function getExpensesForDate(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { data } = await supabase
    .from('petty_cash_expenses')
    .select('*, master_expense_categories(name), profiles(full_name)')
    .eq('expense_date', targetDate)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function getPettyCashTotal(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { data } = await supabase.from('petty_cash_expenses').select('amount').eq('expense_date', targetDate);
  return (data || []).reduce((sum, r) => sum + Number(r.amount), 0);
}

export async function addExpense(categoryId, amount, paidTo, note) {
  const dayGuard = await requireDayOpen();
  if (dayGuard) return dayGuard;

  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const amt = Number(amount);
  if (!categoryId) return { error: 'Select a category.' };
  if (!amt || amt <= 0) return { error: 'Enter a valid amount.' };

  const { data, error } = await supabase
    .from('petty_cash_expenses')
    .insert({
      expense_date: todayIST(),
      category_id: categoryId,
      amount: amt,
      paid_to: paidTo || null,
      note: note || null,
      entered_by: userData?.user?.id || null,
    })
    .select()
    .single();

  if (error) return { error: error.message };
  return { success: true, expense: data };
}

// Deletion is only allowed on today's un-closed entries -- once the
// day is closed, its petty cash total is locked into that closing
// record, same as reconciliation becomes read-only.
export async function deleteExpense(id, expenseDate) {
  if (expenseDate !== todayIST()) return { error: "Only today's entries can be deleted." };
  const closed = await isTodayClosed();
  if (closed) return { error: 'Today is already closed -- petty cash entries are locked.' };

  const supabase = await createClient();
  const { error } = await supabase.from('petty_cash_expenses').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── REVENUE BY DEPARTMENT -- moved here from the Billing Dashboard,
// since it's a same-day revenue breakdown that belongs alongside the
// rest of today's collection summary. ──
export async function getRevenueByDepartmentToday() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data: invoices } = await supabase
    .from('invoices')
    .select('purpose, net')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .neq('status', 'Cancelled');

  const byDept = {};
  (invoices || []).forEach((i) => {
    const dept = i.purpose || 'Other';
    byDept[dept] = (byDept[dept] || 0) + Number(i.net);
  });

  return byDept;
}

export async function getTodayCollectionSummary(date) {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC(date);

  const { data: payments } = await supabase
    .from('payments')
    .select('*, payment_modes(mode, amount), patients(first_name, last_name)')
    .gte('collected_at', startUTC)
    .lte('collected_at', endUTC)
    .order('collected_at', { ascending: false });

  const rows = payments || [];
  const isRefund = (p) => p.payment_type === 'refund';

  const byMode = {};
  rows.forEach((p) => {
    (p.payment_modes || []).forEach((m) => {
      byMode[m.mode] = (byMode[m.mode] || 0) + (isRefund(p) ? -Number(m.amount) : Number(m.amount));
    });
  });

  const total = rows.reduce((s, p) => s + (isRefund(p) ? -Number(p.total_amount) : Number(p.total_amount)), 0);

  return { transactions: rows, byMode, total, count: rows.length };
}

export async function getReconciliationData(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();

  const [summary, pettyCashTotal] = await Promise.all([
    getTodayCollectionSummary(targetDate),
    getPettyCashTotal(targetDate),
  ]);
  const { data: saved } = await supabase.from('day_reconciliation').select('*').eq('closing_date', targetDate);
  const savedByMode = {};
  (saved || []).forEach((r) => { savedByMode[r.mode] = r; });

  // Petty cash is a physical cash outflow, so it only touches the Cash
  // mode's expected figure -- Card/UPI/Cheque/Bank Transfer are
  // untouched. Make sure a Cash row shows up even on a day with
  // expenses but zero cash collections, so it isn't silently skipped.
  const modes = new Set(Object.keys(summary.byMode));
  if (pettyCashTotal > 0) modes.add('Cash');

  return [...modes].map((mode) => {
    const rawExpected = summary.byMode[mode] || 0;
    const expected = mode === 'Cash' ? rawExpected - pettyCashTotal : rawExpected;
    return {
      mode,
      expected,
      actual: savedByMode[mode] ? Number(savedByMode[mode].actual) : expected,
      saved: !!savedByMode[mode],
      reason: savedByMode[mode]?.reason || '',
    };
  });
}

export async function saveReconciliation(mode, expected, actual, reason, approvedBy, date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { error } = await supabase.rpc('save_reconciliation', {
    p_closing_date: targetDate, p_mode: mode, p_expected: expected, p_actual: actual,
    p_reason: reason || null, p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getCloseDayReadiness(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();

  const [reconciliation, { data: alreadyClosed }] = await Promise.all([
    getReconciliationData(targetDate),
    supabase.from('day_closings').select('id').eq('closing_date', targetDate).maybeSingle(),
  ]);

  return {
    reconciliationComplete: reconciliation.every((r) => r.saved),
    alreadyClosed: !!alreadyClosed,
    reconciliation,
  };
}

export async function closeDay(notes, date) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('close_day', { p_date: date || null, p_notes: notes || null });
  if (error) return { error: error.message };
  return { closing: data };
}

// Any day that was opened but never closed, before today. The "Close
// a Past Day" flow works through this list -- and open_day itself now
// refuses to open a new day while any of these exist.
export async function getUnclosedPastDays() {
  const supabase = await createClient();
  const today = todayIST();

  const { data: openings } = await supabase
    .from('day_openings')
    .select('opening_date')
    .lt('opening_date', today)
    .order('opening_date', { ascending: true });
  if (!openings || openings.length === 0) return [];

  const { data: closings } = await supabase
    .from('day_closings')
    .select('closing_date')
    .lt('closing_date', today);
  const closedSet = new Set((closings || []).map((c) => c.closing_date));

  return openings.map((o) => o.opening_date).filter((d) => !closedSet.has(d));
}

export async function getDayClosingHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('day_closings')
    .select('*, profiles(full_name)')
    .order('closing_date', { ascending: false })
    .limit(30);
  return data || [];
}

export async function getDailyReport(date) {
  const supabase = await createClient();
  const [{ data: closing }, { data: reconciliation }, expenses] = await Promise.all([
    supabase.from('day_closings').select('*, profiles(full_name)').eq('closing_date', date).maybeSingle(),
    supabase.from('day_reconciliation').select('*, profiles(full_name)').eq('closing_date', date),
    getExpensesForDate(date),
  ]);
  return { closing, reconciliation: reconciliation || [], expenses };
}

export async function reopenDay(date, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('reopen_day', { p_date: date, p_reason: reason });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getDayOpening() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.from('day_openings').select('*, profiles(full_name)').eq('opening_date', today).maybeSingle();
  return data;
}

export async function openDay(openingBalance, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('open_day', { p_date: null, p_opening_balance: openingBalance || 0, p_remarks: remarks || null });
  if (error) return { error: error.message };
  return { opening: data };
}

export async function isTodayClosed() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.rpc('is_day_closed', { p_date: today });
  return !!data;
}

export async function isTodayOpen() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.from('day_openings').select('id').eq('opening_date', today).maybeSingle();
  return !!data;
}

// Server-side guard for any action that moves physical cash (collect
// payment, refund, advance, or a package invoice that collects an
// advance inline). Called at the top of those actions specifically --
// not a global gate -- so clinical work (doctor, optometry, OT) is
// never blocked by a missed Open Day. Checked here rather than only
// in the UI so it can't be bypassed by calling the server action
// directly. Each new IST calendar date has no day_openings row until
// someone opens it, so this is naturally enforced fresh every day
// without any separate "reset" step.
export async function requireDayOpen() {
  const open = await isTodayOpen();
  if (!open) {
    return { error: "Today's cash day hasn't been opened yet. Go to Cash Management and open the day before collecting or refunding payments." };
  }
  return null;
}


FILEEOF_actions_js

mkdir -p "app/(main)/master-data"
cat > "app/(main)/master-data/actions.js" << 'FILEEOF_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';

async function logMasterAudit(supabase, masterTable, recordCode, action, detail) {
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('master_data_audit_log').insert({
    master_table: masterTable, record_code: recordCode, action, detail, changed_by: userData?.user?.id || null,
  });
}

export async function getMasterAuditLog(masterTable) {
  const supabase = await createClient();
  let q = supabase.from('master_data_audit_log').select('*, profiles(full_name)').order('changed_at', { ascending: false }).limit(30);
  if (masterTable) q = q.eq('master_table', masterTable);
  const { data } = await q;
  return data || [];
}

// Generic toggle works the same way across all master tables -- every
// one of them uses the same status column and Active/Inactive values.
export async function toggleStatus(table, id, currentStatus, code) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from(table).update({ status: newStatus }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, table, code || id, newStatus === 'Active' ? 'Reactivate' : 'Deactivate', `Status changed to ${newStatus}`);
  return { success: true };
}

// ── SHARED HELPERS: auto-code + consistent text formatting ──
// Applied everywhere a person types a free-text name/label into a
// master, so two staff members never accidentally create "iol",
// "IOL", and "Iol" as three different-looking entries, and nobody has
// to invent a unique code by hand.

// Title-cases each word, collapses repeated whitespace, trims ends.
// Deliberately simple/predictable rather than clever -- staff can
// still see exactly what they typed, just consistently capitalized.
function normalizeName(s) {
  return (s || '')
    .trim()
    .replace(/\s+/g, ' ')
    .replace(/\w\S*/g, (w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase());
}

// Derives a short prefix from a category (or a fixed fallback for
// tables with no category concept) -- multi-word categories become an
// initialism ("Minor Procedure" -> MP, "chief_complaint" -> CC), single
// words are used whole if short enough or trimmed to 3 letters
// otherwise ("Cataract" -> CAT, "EDOF" -> EDOF).
function codePrefix(categoryOrFallback) {
  const words = (categoryOrFallback || '').trim().split(/[\s_]+/).filter(Boolean);
  if (words.length === 0) return 'GEN';
  if (words.length === 1) return words[0].length <= 4 ? words[0].toUpperCase() : words[0].slice(0, 3).toUpperCase();
  return words.map((w) => w[0]).join('').toUpperCase().slice(0, 4);
}

// Short alphanumeric codes, auto-generated and linked to category where
// one exists (e.g. Surgery category "Cataract" -> CAT01, CAT02...;
// Procedure category "Minor Procedure" -> MP01, MP02...; History
// Option category "chief_complaint" -> CC01, CC02...). For Clinical
// Master tables with no category concept (IOP Methods, Clinical
// Observations), pass a fixed short fallback prefix instead, so every
// code in Clinical Masters follows the same short PREFIX+NN pattern
// rather than some being long name-derived slugs like the old scheme
// produced.
async function generateCategoryCode(supabase, table, categoryOrFallback) {
  const prefix = codePrefix(categoryOrFallback);
  const { data } = await supabase.from(table).select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(2, '0')}`;
}

// Delete with a friendly message instead of a raw Postgres error when
// the record is still referenced elsewhere (e.g. a service used on a
// past invoice) -- staff should mark it Inactive in that case instead.
async function deleteMasterRecord(supabase, table, id, code) {
  const { error } = await supabase.from(table).delete().eq('id', id);
  if (error) {
    if (error.code === '23503') return { error: 'Cannot delete -- this item is already in use elsewhere (e.g. on a past invoice or record). Set it to Inactive instead.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, table, code || id, 'Delete', 'Record deleted');
  return { success: true };
}

// ── EXPENSE CATEGORIES (Financial Master -- used in Cash Management > Petty Cash) ──
export async function getExpenseCategories() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_expense_categories').select('*').order('name');
  return data || [];
}
export async function addExpenseCategory(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_expense_categories', 'EXP');
  const { error } = await supabase.from('master_expense_categories').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_expense_categories', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateExpenseCategory(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_expense_categories').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_expense_categories', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}

// ── IOP METHODS (Clinical Master -- used in Optometry Assessment) ──
export async function getIopMethods() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iop_methods').select('*').order('name');
  return data || [];
}
export async function addIopMethod(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_iop_methods', 'IOP');
  const { error } = await supabase.from('master_iop_methods').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iop_methods', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateIopMethod(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_iop_methods').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_iop_methods', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteIopMethod(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iop_methods', id, code);
}

// ── DRUG TYPES (Financial Master -- Pharmacy tab, drives what dosage
// phrasing options the doctor's Prescription picker shows) ──
export async function getDrugTypes() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drug_types').select('*').order('name');
  return data || [];
}
export async function addDrugType(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_drug_types', 'TYP');
  const { error } = await supabase.from('master_drug_types').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drug_types', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDrugType(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_drug_types').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_drug_types', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteDrugType(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drug_types', id, code);
}

// Dosage phrasing options nested under a drug type -- e.g. "Apply thin
// layer" under Eye Ointment, "1 drop" under Eye Drop. Simple list items
// (like Package line items), not full master records, so no audit code.
export async function getDosageOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_dosage_options').select('*').eq('status', 'Active').order('display_order');
  return data || [];
}
export async function addDosageOption(drugTypeId, dosageText) {
  const supabase = await createClient();
  const text = (dosageText || '').trim();
  if (!text) return { error: 'Dosage text is required.' };
  const { data: existing } = await supabase.from('master_dosage_options').select('display_order').eq('drug_type_id', drugTypeId).order('display_order', { ascending: false }).limit(1);
  const nextOrder = (existing?.[0]?.display_order ?? 0) + 1;
  const { error } = await supabase.from('master_dosage_options').insert({ drug_type_id: drugTypeId, dosage_text: text, display_order: nextOrder });
  if (error) return { error: error.message };
  return { success: true };
}
export async function removeDosageOption(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_dosage_options').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGICAL CONSUMABLES (Clinical Master -- Patient Check-In dropdown
// and Intraoperative Management quick-pick, both in OT Intraop) ──
export async function getSurgicalConsumablesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgical_consumables').select('*').order('name');
  return data || [];
}
export async function addSurgicalConsumable(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_surgical_consumables', 'CONS');
  const { error } = await supabase.from('master_surgical_consumables').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgical_consumables', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgicalConsumable(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_surgical_consumables').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_surgical_consumables', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteSurgicalConsumable(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgical_consumables', id, code);
}

// ── CLINICAL OBSERVATIONS (Clinical Master -- quick-pick chips in
// Optometry Assessment's Clinical Observations section) ──
export async function getClinicalObservations() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_clinical_observations').select('*').order('name');
  return data || [];
}
export async function addClinicalObservation(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_clinical_observations', 'OBS');
  const { error } = await supabase.from('master_clinical_observations').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_clinical_observations', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateClinicalObservation(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_clinical_observations').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_clinical_observations', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteClinicalObservation(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_clinical_observations', id, code);
}

// ── HISTORY OPTIONS (Clinical Master -- chip options in the doctor's
// Consultation History tab: Chief Complaint, Ocular/Medical/Family
// History). Four categories in one table; code is unique per category
// (not globally) since e.g. "Glaucoma" is a legitimate chip in both
// Ocular History and Family History. ──
export async function getHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_history_options').select('*').order('category').order('name');
  return data || [];
}
export async function addHistoryOption(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_history_options', values.category);
  const { error } = await supabase.from('master_history_options').insert({ code, name, category: values.category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_history_options', code, 'Create', `${name} (${values.category}) created`);
  return { success: true };
}
export async function updateHistoryOption(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_history_options').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_history_options', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteHistoryOption(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_history_options', id, code);
}

// Active-only, grouped by category -- what the doctor's Consultation
// History tab actually renders as selectable chips
// (app/(main)/consultation/[id]/history-tab.js).
export async function getActiveHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_history_options')
    .select('category, name')
    .eq('status', 'Active')
    .order('name');

  const grouped = { chief_complaint: [], ocular_history: [], medical_history: [], family_history: [], drug_history: [], allergy: [] };
  (data || []).forEach((row) => {
    if (grouped[row.category]) grouped[row.category].push(row.name);
  });
  return grouped;
}

// ── DOCTORS (Clinical Master) ──
// Deliberately NOT a separate table -- doctors are profiles (same
// source User Management and Appointments' doctor dropdown already
// use). This is a management view onto that same data, filtered to
// doctor-type designations, showing both Active and Inactive (unlike
// the dropdown-facing getDoctors() in appointments/actions.js, which
// only wants Active ones). New doctor accounts are still created in
// User Management (needs a real login, service-role auth), and name
// changes belong there too (it's tied to their login identity) -- so
// this tab intentionally offers status management only, no Edit/Delete.
export async function getDoctorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, code, full_name, designation, status')
    .eq('designation', 'Doctor')
    .order('full_name');
  const doctors = data || [];

  // Self-heal: any doctor profile created via User Management since this
  // was added (or missed by the one-time backfill) won't have a code yet.
  // Assign the next one in the same uniform DOC01, DOC02... sequence used
  // everywhere else in Clinical Masters, rather than anything category- or
  // designation-specific.
  const missing = doctors.filter((d) => !d.code);
  for (const d of missing) {
    // Re-queried fresh each time so each new code accounts for the one
    // just assigned above it.
    const code = await generateCategoryCode(supabase, 'profiles', 'DOC');
    const { error } = await supabase.from('profiles').update({ code }).eq('id', d.id);
    if (!error) d.code = code;
  }
  return doctors;
}

// ── SERVICES ──
// Services (Consultation, Investigation, Surgery, Pharmacy departments
// in master_services) follow their own long-established CON001, INV001...
// pattern -- 3-digit, scoped per department -- rather than the 2-digit
// generateCategoryCode scheme above. Kept separate so it stays exactly
// consistent with the codes already seeded in the database.
async function generateServiceCode(supabase, dept) {
  const prefix = (dept || 'SVC').slice(0, 3).toUpperCase();
  const { data } = await supabase.from('master_services').select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function getServices() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').order('name');
  return data || [];
}
export async function addService(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateServiceCode(supabase, values.dept);
  const { error } = await supabase.from('master_services').insert({
    code, name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
    investigation_package: values.investigationPackage?.trim() || null,
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_services', code, 'Create', `${name} created -- Rs.${values.rate}, ${values.gstPct || 0}% GST`);
  return { success: true };
}
export async function updateService(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_services').update({
    name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
    investigation_package: values.investigationPackage?.trim() || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  if (oldValues.dept !== values.dept) changes.push(`Dept ${oldValues.dept} -> ${values.dept}`);
  if ((oldValues.investigation_package || '') !== (values.investigationPackage || '')) changes.push(`Package ${oldValues.investigation_package || '--'} -> ${values.investigationPackage || '--'}`);
  await logMasterAudit(supabase, 'master_services', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteService(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_services', id, code);
}

// ── PACKAGES ──
export async function getPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*, master_surgeries(name)').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { data: code, error: codeError } = await supabase.rpc('next_package_code');
  if (codeError) return { error: codeError.message };
  const { data: newPackage, error } = await supabase.from('master_packages').insert({
    code, name, price: 0, includes: values.includes ? normalizeName(values.includes) : null,
    surgery_id: values.surgeryId || null, status: 'Active',
    iol_category: values.iolCategory || null, origin: values.origin || null,
  }).select().single();
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_packages', code, 'Create', `${name} created`);
  return { success: true, package: newPackage };
}
export async function updatePackage(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const includes = values.includes ? normalizeName(values.includes) : values.includes;
  const { error } = await supabase.from('master_packages').update({
    name, includes, surgery_id: values.surgeryId || null,
    iol_category: values.iolCategory || null, origin: values.origin || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.includes !== includes) changes.push('Includes updated');
  if ((oldValues.iol_category || '') !== (values.iolCategory || '')) changes.push(`IOL type ${oldValues.iol_category || '--'} -> ${values.iolCategory || '--'}`);
  if ((oldValues.origin || '') !== (values.origin || '')) changes.push(`Origin ${oldValues.origin || '--'} -> ${values.origin || '--'}`);
  await logMasterAudit(supabase, 'master_packages', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deletePackage(id, code) {
  const supabase = await createClient();
  // Constituents belong to the package -- clear them first so the
  // package row itself isn't blocked by its own line items.
  await supabase.from('package_line_items').delete().eq('package_id', id);
  return deleteMasterRecord(supabase, 'master_packages', id, code);
}

// ── PACKAGE CONSTITUENTS (breakup for billing / insurance requests) ──
export async function getPackageLineItems(packageId) {
  const supabase = await createClient();
  const { data } = await supabase.from('package_line_items').select('*').eq('package_id', packageId).order('sort_order');
  return data || [];
}
export async function addPackageLineItem(packageId, description, amount) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('package_line_items').select('sort_order').eq('package_id', packageId).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  const { error } = await supabase.from('package_line_items').insert({
    package_id: packageId, description: normalizeName(description), amount: parseFloat(amount) || 0, sort_order: (existing?.sort_order || 0) + 1,
  });
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', `Constituent added: ${normalizeName(description)} -- Rs.${amount}`);
  return { success: true };
}
export async function removePackageLineItem(id, packageId) {
  const supabase = await createClient();
  const { error } = await supabase.from('package_line_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', 'Constituent removed');
  return { success: true };
}

// ── PROCEDURES (Clinical Master -- minor, in-clinic procedures a doctor
// performs directly, e.g. "Syringing", "FB Removal". Distinct from
// SURGERIES below, which are OT-based and back billing Packages.) ──
export async function getProcedures() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_procedures').select('*').order('name');
  return data || [];
}
export async function addProcedure(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_procedures', category);
  const { error } = await supabase.from('master_procedures').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_procedures', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateProcedure(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_procedures').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_procedures', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteProcedure(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_procedures', id, code);
}

// ── SURGERIES (Clinical Master -- the OT-based surgery a doctor advises,
// e.g. "Phaco Cataract Surgery". No price -- pure clinical classification.
// Multiple billing Packages can point at one surgery, sub-classified by
// IOL type/origin for Cataract.) ──
export async function getSurgeries() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('*').order('name');
  return data || [];
}
export async function addSurgery(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_surgeries', 'SUR');
  const { error } = await supabase.from('master_surgeries').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgeries', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgery(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_surgeries').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_surgeries', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteSurgery(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgeries', id, code);
}

// ── DRUGS ──
export async function getDrugs() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drugs').select('*, master_drug_types(id, name)').order('generic');
  return data || [];
}
// Drugs (Pharmacy tab) -- fixed "DRG" prefix, 3-digit sequence, same
// PREFIX+NNN shape as Services (CON001...) and Packages (PKG001...)
// rather than the old name-derived slug codes.
async function generateDrugCode(supabase) {
  const { data } = await supabase.from('master_drugs').select('code').ilike('code', 'DRG%');
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(/^DRG(\d+)$/);
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `DRG${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function addDrug(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const code = await generateDrugCode(supabase);
  const { error } = await supabase.from('master_drugs').insert({
    code, brand, generic, strength: values.strength, form: normalizeName(values.form),
    drug_type_id: values.drugTypeId || null,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drugs', code, 'Create', `${generic} (${brand}) created -- Rs.${values.rate}`);
  return { success: true };
}
export async function updateDrug(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const form = normalizeName(values.form);
  const { error } = await supabase.from('master_drugs').update({
    brand, generic, strength: values.strength, form,
    drug_type_id: values.drugTypeId || null,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.generic !== generic) changes.push(`Generic ${oldValues.generic} -> ${generic}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  await logMasterAudit(supabase, 'master_drugs', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteDrug(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drugs', id, code);
}

// ── DIAGNOSES ──
export async function getDiagnosesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_diagnoses').select('*').order('name');
  return data || [];
}
export async function addDiagnosisMaster(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_diagnoses', 'DIAG');
  const { error } = await supabase.from('master_diagnoses').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_diagnoses', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDiagnosisMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_diagnoses').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_diagnoses', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteDiagnosisMaster(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_diagnoses', id, code);
}

// ── IOL CATALOG (Clinical Master, M29 -- referenced by Biometry &
// IOL Planning's Surgeon Approval screen). Brand/model act as the
// name-equivalent fields for code generation and normalization. ──
export async function getIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iol_catalog').select('*').order('brand').order('model');
  return data || [];
}
export async function addIolCatalogItem(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const code = await generateCategoryCode(supabase, 'master_iol_catalog', 'IOL');
  const { error } = await supabase.from('master_iol_catalog').insert({
    code, brand, model, manufacturer, category: values.category, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iol_catalog', code, 'Create', `${brand} -- ${model} (${values.category}) created`);
  return { success: true };
}
export async function updateIolCatalogItem(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const { error } = await supabase.from('master_iol_catalog').update({ brand, model, manufacturer, category: values.category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.brand !== brand) changes.push(`Brand ${oldValues.brand} -> ${brand}`);
  if (oldValues.model !== model) changes.push(`Model ${oldValues.model} -> ${model}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  await logMasterAudit(supabase, 'master_iol_catalog', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteIolCatalogItem(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iol_catalog', id, code);
}

// Active-only, grouped by category -- what Surgeon Approval's "Specific
// IOL" dropdown actually consumes.
export async function getActiveIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_iol_catalog')
    .select('id, code, brand, model, manufacturer, category')
    .eq('status', 'Active')
    .order('brand');
  return data || [];
}

// NOTE: Investigations previously had their own master_investigations
// table here, but it was empty and unused everywhere except this
// module -- every real investigation (with its actual rate) already
// lives in master_services where dept = 'Investigation'. Consolidated
// into Financial Masters (Migration 48) to avoid the same item ever
// having two different prices in two different places.



FILEEOF_actions_js

mkdir -p "supabase/migrations"
cat > "supabase/migrations/028_petty_cash.sql" << 'FILEEOF_028_petty_cash_sql'
-- Petty Cash Expenses
-- Tracks the hospital's own day-to-day cash outgoings (stationery,
-- transport, refreshments, minor repairs, etc.) so Close Day
-- reconciliation for the Cash mode ties out against what actually
-- left the drawer, not just what came in.

-- ── Expense Categories (Financial Masters) ──
CREATE TABLE IF NOT EXISTS "public"."master_expense_categories" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "code" text NOT NULL,
    "name" text NOT NULL,
    "status" text NOT NULL DEFAULT 'Active'
);

ALTER TABLE "public"."master_expense_categories" OWNER TO "postgres";

ALTER TABLE ONLY "public"."master_expense_categories"
    ADD CONSTRAINT "master_expense_categories_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."master_expense_categories"
    ADD CONSTRAINT "master_expense_categories_code_key" UNIQUE ("code");

ALTER TABLE "public"."master_expense_categories"
    ADD CONSTRAINT "master_expense_categories_status_check" CHECK (("status" = ANY (ARRAY['Active'::text, 'Inactive'::text])));

ALTER TABLE "public"."master_expense_categories" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_all_access" ON "public"."master_expense_categories" TO "authenticated" USING (true) WITH CHECK (true);

GRANT ALL ON TABLE "public"."master_expense_categories" TO "anon";
GRANT ALL ON TABLE "public"."master_expense_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."master_expense_categories" TO "service_role";

INSERT INTO "public"."master_expense_categories" (code, name) VALUES
  ('STA01', 'Stationery'),
  ('TRA01', 'Transport'),
  ('REF01', 'Refreshments'),
  ('REP01', 'Repairs & Maintenance'),
  ('MIS01', 'Miscellaneous')
ON CONFLICT (code) DO NOTHING;


-- ── Petty Cash Expenses ──
-- Entered by any staff on a day that is currently open (same
-- requireDayOpen() guard used by payment collection/refund). No
-- approval step by design -- kept lightweight, matching the low-stakes
-- nature of day-to-day petty spend.
CREATE TABLE IF NOT EXISTS "public"."petty_cash_expenses" (
    "id" uuid DEFAULT gen_random_uuid() NOT NULL,
    "expense_date" date NOT NULL,
    "category_id" uuid NOT NULL,
    "amount" numeric NOT NULL,
    "paid_to" text,
    "note" text,
    "entered_by" uuid,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "petty_cash_expenses_amount_check" CHECK (("amount" > 0))
);

ALTER TABLE "public"."petty_cash_expenses" OWNER TO "postgres";

ALTER TABLE ONLY "public"."petty_cash_expenses"
    ADD CONSTRAINT "petty_cash_expenses_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."petty_cash_expenses"
    ADD CONSTRAINT "petty_cash_expenses_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."master_expense_categories"("id");

ALTER TABLE ONLY "public"."petty_cash_expenses"
    ADD CONSTRAINT "petty_cash_expenses_entered_by_fkey" FOREIGN KEY ("entered_by") REFERENCES "public"."profiles"("id");

CREATE INDEX "idx_petty_cash_expenses_date" ON "public"."petty_cash_expenses" USING "btree" ("expense_date");

ALTER TABLE "public"."petty_cash_expenses" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "staff_all_access" ON "public"."petty_cash_expenses" TO "authenticated" USING (true) WITH CHECK (true);

GRANT ALL ON TABLE "public"."petty_cash_expenses" TO "anon";
GRANT ALL ON TABLE "public"."petty_cash_expenses" TO "authenticated";
GRANT ALL ON TABLE "public"."petty_cash_expenses" TO "service_role";


-- ── Fold into Close Day ──
-- Stores the day's total petty cash spend alongside the other
-- Close Day totals, so Daily Report/History show it without a
-- separate join every time.
ALTER TABLE "public"."day_closings" ADD COLUMN IF NOT EXISTS "total_petty_cash_expenses" numeric DEFAULT 0 NOT NULL;

CREATE OR REPLACE FUNCTION "public"."close_day"("p_date" "date" DEFAULT NULL::"date", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."day_closings"
    LANGUAGE "plpgsql"
    AS $$
declare
  closing day_closings;
  v_revenue numeric;
  v_collected numeric;
  v_outstanding numeric;
  v_invoice_count int;
  v_visit_count int;
  v_date date;
  v_modes_expected int;
  v_modes_reconciled int;
  v_petty_cash numeric;
begin
  v_date := coalesce(p_date, ist_date(now()));

  if is_day_closed(v_date) then
    raise exception 'This day has already been closed.';
  end if;

  select count(distinct pm.mode) into v_modes_expected
  from payment_modes pm join payments p on p.id = pm.payment_id
  where ist_date(p.collected_at) = v_date;

  select count(*) into v_modes_reconciled from day_reconciliation where closing_date = v_date;

  if v_modes_expected > 0 and v_modes_reconciled < v_modes_expected then
    raise exception 'Reconciliation is incomplete for %s -- % of % payment modes reconciled. Complete reconciliation before closing.', v_date, v_modes_reconciled, v_modes_expected;
  end if;

  select coalesce(sum(net),0), coalesce(sum(paid),0), coalesce(sum(net - paid),0), count(*)
  into v_revenue, v_collected, v_outstanding, v_invoice_count
  from invoices where ist_date(created_at) = v_date;

  select count(*) into v_visit_count from visits where ist_date(created_at) = v_date;

  select coalesce(sum(amount),0) into v_petty_cash from petty_cash_expenses where expense_date = v_date;

  insert into day_closings (closing_date, closed_by, total_revenue, total_collected, total_outstanding, total_invoices, total_visits, notes, total_petty_cash_expenses)
  values (v_date, auth.uid(), v_revenue, v_collected, v_outstanding, v_invoice_count, v_visit_count, p_notes, v_petty_cash)
  returning * into closing;

  return closing;
end;
$$;

FILEEOF_028_petty_cash_sql

echo "Files written."

git add -A
git commit -m "Add Petty Cash: expense entry, category master, Cash reconciliation net-off, Daily Report breakdown"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
