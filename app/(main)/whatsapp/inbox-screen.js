'use client';

// WhatsApp Inbox screen (migration 053).
//   * Left: conversations (newest first), unread counts, matched patient.
//     Refreshes itself every 20s while the tab is visible -- one request.
//   * Right: the chat. Patient messages, our replies, and the template
//     messages the hospital sent this number (bills, feedback...) for context.
//   * Reply box: free text, only inside WhatsApp's 24-hour window.
//   * ?m=<mobile> opens a chat directly.

import { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { useVisibleInterval } from '@/lib/useVisibleInterval';
import { getWhatsAppInbox } from '@/lib/rpc-reads/whatsapp__actions'; // parallel reads (tools/parallel-reads)
import { openWhatsAppThread, sendWhatsAppReply } from './actions';

const REPLY_WINDOW_MS = 24 * 60 * 60 * 1000;

const TEMPLATE_LABEL = {
  registration: 'Registration confirmation',
  appointment: 'Visit confirmation',
  bill_template_with_pdf: 'Bill (PDF)',
  payment_receipt: 'Payment receipt',
  advance_receipt: 'Advance receipt',
  feedback_veda: 'Feedback / Google review request',
};

const timeIST = (d) => new Date(d).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
const dayIST = (d) => new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
function listWhen(d, now) {
  const a = dayIST(d);
  if (a === dayIST(now)) return timeIST(d);
  const y = new Date(new Date(now).getTime() - 86400000);
  if (a === dayIST(y)) return 'Yesterday';
  return new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short' });
}
const prettyMobile = (m) => (m && m.length === 12 && m.startsWith('91') ? `+91 ${m.slice(2, 7)} ${m.slice(7)}` : `+${m}`);

function convTitle(c) {
  if (c.patients?.length) {
    const first = formatPatientName(c.patients[0]);
    return c.patients.length > 1 ? `${first} +${c.patients.length - 1}` : first;
  }
  return c.contact_name || c.contactName || prettyMobile(c.mobile);
}

const TYPE_ICON = { image: 'ti-photo', video: 'ti-video', audio: 'ti-microphone', document: 'ti-file', sticker: 'ti-mood-smile', location: 'ti-map-pin', contacts: 'ti-address-book', reaction: 'ti-heart' };

function StatusTick({ status, error }) {
  if (status === 'failed') return <i className="ti ti-alert-circle" title={error || 'Failed'} style={{ color: 'var(--red)' }}></i>;
  if (status === 'read') return <i className="ti ti-checks" title="Read" style={{ color: '#2b8ae6' }}></i>;
  if (status === 'delivered') return <i className="ti ti-checks" title="Delivered" style={{ color: 'var(--g400)' }}></i>;
  return <i className="ti ti-check" title="Sent" style={{ color: 'var(--g400)' }}></i>;
}

function Media({ m }) {
  if (!m.media_id) return null;
  const src = `/api/whatsapp/media/${encodeURIComponent(m.media_id)}`;
  if (m.msg_type === 'image' || m.msg_type === 'sticker') {
    return <a href={src} target="_blank" rel="noreferrer"><img src={src} alt="" loading="lazy" className="wa-img" /></a>;
  }
  if (m.msg_type === 'audio') return <audio controls preload="none" src={src} style={{ maxWidth: 260 }} />;
  if (m.msg_type === 'video') return <video controls preload="none" src={src} className="wa-img" />;
  return (
    <a href={src} target="_blank" rel="noreferrer" className="btn btn-sm" style={{ marginBottom: 4 }}>
      <i className="ti ti-file-download"></i> {m.media_filename || 'Open document'}
    </a>
  );
}

function Bubble({ m, byWaId, onReply, canReply }) {
  const out = m.direction === 'out';
  const quoted = m.reply_to_wa_id && m.msg_type !== 'reaction' ? byWaId[m.reply_to_wa_id] : null;
  return (
    <div className={`wa-row ${out ? 'out' : 'in'}`}>
      <div className={`wa-bubble ${out ? 'out' : 'in'}`}>
        {quoted && <div className="wa-quote">{quoted.body || quoted.msg_type}</div>}
        <Media m={m} />
        {m.body && (
          <div className="wa-text">
            {TYPE_ICON[m.msg_type] && !m.media_id && <i className={`ti ${TYPE_ICON[m.msg_type]}`} style={{ marginRight: 4 }}></i>}
            {m.body}
          </div>
        )}
        <div className="wa-meta">
          {out && m.sent_by_name && <span>{m.sent_by_name} · </span>}
          {timeIST(m.message_at)}
          {out && <> <StatusTick status={m.status} error={m.error_message} /></>}
          {!out && canReply && m.wa_message_id && (
            <button type="button" className="wa-replybtn" title="Reply to this message" onClick={() => onReply(m)}>
              <i className="ti ti-arrow-back-up"></i>
            </button>
          )}
        </div>
        {out && m.status === 'failed' && m.error_message && <div className="wa-fail">{m.error_message}</div>}
      </div>
    </div>
  );
}

export default function WhatsAppInbox() {
  const searchParams = useSearchParams();
  const router = useRouter();

  const [inbox, setInbox] = useState(null);
  const [inboxError, setInboxError] = useState('');
  const [search, setSearch] = useState('');
  const [unreadOnly, setUnreadOnly] = useState(false);

  const [selected, setSelected] = useState(searchParams.get('m') || '');
  const [thread, setThread] = useState(null);
  const [threadLoading, setThreadLoading] = useState(false);
  const [threadError, setThreadError] = useState('');

  const [text, setText] = useState('');
  const [replyTo, setReplyTo] = useState(null);
  const [sending, setSending] = useState(false);
  const [sendMsg, setSendMsg] = useState(null); // { kind: 'err'|'warn', text }

  const bottomRef = useRef(null);
  const filters = useRef({ search: '', unreadOnly: false });
  filters.current = { search, unreadOnly };

  const loadInbox = useCallback(async () => {
    try {
      const r = await getWhatsAppInbox(filters.current);
      if (r?.error) setInboxError(r.error);
      else { setInbox(r); setInboxError(''); }
    } catch (e) {
      setInboxError(e.message || 'Could not load the inbox.');
    }
  }, []);

  // Search: wait for typing to pause.
  useEffect(() => {
    const t = setTimeout(loadInbox, search ? 300 : 0);
    return () => clearTimeout(t);
  }, [search, unreadOnly, loadInbox]);

  useVisibleInterval(loadInbox, 20000);

  const openThread = useCallback(async (mobile, { quiet = false } = {}) => {
    if (!mobile) return;
    if (!quiet) { setThreadLoading(true); setThreadError(''); }
    try {
      const r = await openWhatsAppThread(mobile);
      if (r?.error) setThreadError(r.error);
      else {
        setThread(r);
        // Opening a chat marks it read -- reflect that in the list straight away.
        setInbox((prev) => prev && {
          ...prev,
          totalUnread: Math.max(0, (prev.totalUnread || 0) - (prev.conversations.find((c) => c.mobile === mobile)?.unread || 0)),
          conversations: prev.conversations.map((c) => (c.mobile === mobile ? { ...c, unread: 0 } : c)),
        });
      }
    } catch (e) {
      setThreadError(e.message || 'Could not open this chat.');
    } finally {
      if (!quiet) setThreadLoading(false);
    }
  }, []);

  useEffect(() => {
    if (selected) openThread(selected);
    else setThread(null);
    setText(''); setReplyTo(null); setSendMsg(null);
  }, [selected, openThread]);

  // A new message arrived in the chat that's open (seen on the 20s list refresh).
  const selectedConv = inbox?.conversations?.find((c) => c.mobile === selected);
  const threadLatest = thread?.messages?.length ? thread.messages[thread.messages.length - 1].message_at : null;
  useEffect(() => {
    if (!selectedConv || !thread || thread.mobile !== selected) return;
    if (threadLatest && new Date(selectedConv.last_at) > new Date(threadLatest)) openThread(selected, { quiet: true });
  }, [selectedConv?.last_at]); // eslint-disable-line react-hooks/exhaustive-deps

  const items = useMemo(() => {
    if (!thread) return [];
    const msgs = (thread.messages || []).map((m) => ({ kind: 'msg', at: m.message_at, m }));
    const tpls = (thread.templates || []).map((t) => ({ kind: 'tpl', at: t.sent_at, t }));
    return [...msgs, ...tpls].sort((a, b) => new Date(a.at) - new Date(b.at));
  }, [thread]);

  const byWaId = useMemo(() => Object.fromEntries((thread?.messages || []).filter((m) => m.wa_message_id).map((m) => [m.wa_message_id, m])), [thread]);

  useEffect(() => { bottomRef.current?.scrollIntoView({ block: 'end' }); }, [items.length, selected]);

  function select(mobile) {
    setSelected(mobile);
    const url = mobile ? `/whatsapp?m=${encodeURIComponent(mobile)}` : '/whatsapp';
    router.replace(url, { scroll: false });
  }

  const now = thread?.now || inbox?.now || new Date().toISOString();
  const lastIn = thread?.lastInboundAt;
  const windowLeftMs = lastIn ? REPLY_WINDOW_MS - (new Date(now) - new Date(lastIn)) : -1;
  const canReply = windowLeftMs > 0;
  const hoursLeft = Math.floor(windowLeftMs / 3600000);
  const minsLeft = Math.max(0, Math.floor((windowLeftMs % 3600000) / 60000));

  async function send() {
    if (!text.trim() || sending) return;
    setSending(true); setSendMsg(null);
    try {
      const r = await sendWhatsAppReply({ mobile: selected, text, replyToWaId: replyTo?.wa_message_id || null });
      if (r?.thread) setThread(r.thread);
      if (r?.error) setSendMsg({ kind: 'err', text: r.error });
      else {
        if (r?.warning) setSendMsg({ kind: 'warn', text: r.warning });
        setText(''); setReplyTo(null);
        setInbox((prev) => prev && {
          ...prev,
          conversations: prev.conversations.map((c) => (c.mobile === selected
            ? { ...c, last_at: new Date().toISOString(), last_direction: 'out', last_type: 'text', last_body: text.trim() } : c)),
        });
      }
    } catch (e) {
      setSendMsg({ kind: 'err', text: e.message || 'Could not send -- check your connection and try again.' });
    } finally {
      setSending(false);
    }
  }

  const conversations = inbox?.conversations || [];
  const headerName = thread ? convTitle({ ...thread, mobile: thread.mobile }) : '';

  let lastDay = '';

  return (
    <div className={`wa-wrap ${selected ? 'has-sel' : ''}`}>
      <style>{CSS}</style>

      {/* ── Conversation list ─────────────────────────────────── */}
      <div className="wa-list card">
        <div className="wa-list-head">
          <div className="card-title" style={{ margin: 0 }}>
            <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i> WhatsApp Inbox
            {inbox?.totalUnread > 0 && <span className="badge b-green">{inbox.totalUnread} unread</span>}
          </div>
          <input className="fi fi-sm" placeholder="Search name, UHID or number" value={search} onChange={(e) => setSearch(e.target.value)} />
          <div className="wa-filter">
            <button type="button" className={`btn btn-sm ${!unreadOnly ? 'btn-primary' : ''}`} onClick={() => setUnreadOnly(false)}>All</button>
            <button type="button" className={`btn btn-sm ${unreadOnly ? 'btn-primary' : ''}`} onClick={() => setUnreadOnly(true)}>Unread</button>
          </div>
        </div>
        {inboxError && <div className="msg-err" style={{ margin: 10 }}>{inboxError}</div>}
        <div className="wa-convs">
          {!inbox && !inboxError && <div className="wa-empty">Loading...</div>}
          {inbox && conversations.length === 0 && (
            <div className="wa-empty">
              {search || unreadOnly ? 'No chats match.' : 'No patient replies yet. They will appear here as soon as patients reply to the hospital\'s WhatsApp messages.'}
            </div>
          )}
          {conversations.map((c) => (
            <button type="button" key={c.mobile} className={`wa-conv ${c.mobile === selected ? 'active' : ''}`} onClick={() => select(c.mobile)}>
              <div className="wa-avatar"><i className="ti ti-user"></i></div>
              <div className="wa-conv-main">
                <div className="wa-conv-top">
                  <span className="wa-conv-name">{convTitle(c)}</span>
                  <span className={`wa-conv-time ${c.unread > 0 ? 'unread' : ''}`}>{listWhen(c.last_at, inbox.now)}</span>
                </div>
                <div className="wa-conv-bottom">
                  <span className="wa-conv-last">
                    {c.last_direction === 'out' && <i className="ti ti-arrow-back-up" style={{ marginRight: 3 }}></i>}
                    {TYPE_ICON[c.last_type] && <i className={`ti ${TYPE_ICON[c.last_type]}`} style={{ marginRight: 3 }}></i>}
                    {c.last_body || c.last_type}
                  </span>
                  {c.unread > 0 && <span className="wa-unread">{c.unread}</span>}
                </div>
                <div className="wa-conv-sub">{c.patients?.[0]?.uhid ? `${c.patients[0].uhid} · ` : ''}{prettyMobile(c.mobile)}</div>
              </div>
            </button>
          ))}
        </div>
      </div>

      {/* ── Chat ──────────────────────────────────────────────── */}
      <div className="wa-chat card">
        {!selected && (
          <div className="wa-placeholder">
            <i className="ti ti-message-circle" style={{ fontSize: 40, color: 'var(--g300)' }}></i>
            <div>Select a chat to read and reply.</div>
          </div>
        )}
        {selected && (
          <>
            <div className="wa-chat-head">
              <button type="button" className="btn btn-sm wa-back" onClick={() => select('')}><i className="ti ti-arrow-left"></i></button>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div className="wa-chat-name">{headerName || prettyMobile(selected)}</div>
                <div className="wa-chat-sub">
                  {prettyMobile(selected)}
                  {thread?.contactName && <> · WhatsApp name: {thread.contactName}</>}
                </div>
                {thread?.patients?.length > 0 && (
                  <div className="wa-patients">
                    {thread.patients.map((p) => (
                      <Link key={p.id} href={`/patient-timeline?patientId=${p.id}`} className="badge b-blue" title="Open patient timeline">
                        {formatPatientName(p)} · {p.uhid}{p.age ? ` · ${p.age}${p.gender ? ' ' + p.gender : ''}` : ''}
                      </Link>
                    ))}
                  </div>
                )}
                {thread && thread.patients?.length === 0 && <div className="wa-chat-sub" style={{ color: 'var(--amber)' }}>No registered patient with this mobile number.</div>}
              </div>
            </div>

            <div className="wa-thread">
              {threadLoading && !thread && <div className="wa-empty">Loading chat...</div>}
              {threadError && <div className="msg-err" style={{ margin: 10 }}>{threadError}</div>}
              {thread && items.map((it) => {
                const d = dayIST(it.at);
                const sep = d !== lastDay ? (lastDay = d, <div key={`d-${d}`} className="wa-day"><span>{d === dayIST(now) ? 'Today' : d}</span></div>) : null;
                if (it.kind === 'tpl') {
                  return [sep, (
                    <div key={`t-${it.t.id}`} className="wa-tpl">
                      <i className="ti ti-template"></i> Hospital sent: <strong>{TEMPLATE_LABEL[it.t.template_name] || it.t.template_name}</strong>
                      {' · '}{timeIST(it.t.sent_at)}{it.t.sent_by_name ? ` · ${it.t.sent_by_name}` : ''}
                    </div>
                  )];
                }
                return [sep, <Bubble key={it.m.id} m={it.m} byWaId={byWaId} canReply={canReply} onReply={setReplyTo} />];
              })}
              <div ref={bottomRef} />
            </div>

            <div className="wa-compose">
              {sendMsg && <div className={sendMsg.kind === 'err' ? 'msg-err' : 'msg-info'} style={{ marginBottom: 8 }}>{sendMsg.text}</div>}
              {thread && !canReply && (
                <div className="msg-info" style={{ marginBottom: 0 }}>
                  <i className="ti ti-clock-off"></i>
                  {lastIn
                    ? "More than 24 hours since this patient's last message -- WhatsApp only allows approved templates now. Call the patient, or reply when they message again."
                    : 'This patient has not messaged yet -- WhatsApp only allows replies after the patient writes.'}
                </div>
              )}
              {thread && canReply && (
                <>
                  {replyTo && (
                    <div className="wa-replying">
                      <span><i className="ti ti-arrow-back-up"></i> Replying to: {replyTo.body || replyTo.msg_type}</span>
                      <button type="button" className="wa-replybtn" onClick={() => setReplyTo(null)}><i className="ti ti-x"></i></button>
                    </div>
                  )}
                  <div className="wa-compose-row">
                    <textarea
                      className="fi"
                      rows={2}
                      placeholder="Type a reply... (Ctrl+Enter to send)"
                      value={text}
                      maxLength={4096}
                      onChange={(e) => setText(e.target.value)}
                      onKeyDown={(e) => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); send(); } }}
                    />
                    <button type="button" className="btn btn-green" disabled={sending || !text.trim()} onClick={send}>
                      <i className="ti ti-send"></i> {sending ? 'Sending...' : 'Send'}
                    </button>
                  </div>
                  <div className="wa-window">Reply window closes in {hoursLeft}h {minsLeft}m</div>
                </>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

const CSS = `
.wa-wrap { display: grid; grid-template-columns: 340px 1fr; gap: 14px; height: calc(100vh - 120px); min-height: 480px; }
.wa-wrap .card { margin-bottom: 0; padding: 0; display: flex; flex-direction: column; overflow: hidden; }
.wa-list-head { padding: 14px; border-bottom: 1px solid var(--g200); display: flex; flex-direction: column; gap: 10px; }
.wa-filter { display: flex; gap: 6px; }
.wa-convs { overflow-y: auto; flex: 1; }
.wa-empty { padding: 24px 16px; color: var(--g500); font-size: 12.5px; text-align: center; }
.wa-conv { display: flex; gap: 10px; width: 100%; text-align: left; padding: 10px 14px; border: 0; border-bottom: 1px solid var(--g100); background: transparent; cursor: pointer; font: inherit; }
.wa-conv:hover { background: var(--g50); }
.wa-conv.active { background: var(--green-lt); }
.wa-avatar { width: 36px; height: 36px; border-radius: 50%; background: var(--g100); color: var(--g500); display: flex; align-items: center; justify-content: center; flex-shrink: 0; font-size: 18px; }
.wa-conv-main { min-width: 0; flex: 1; }
.wa-conv-top, .wa-conv-bottom { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.wa-conv-name { font-weight: 600; font-size: 13px; color: var(--g900); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wa-conv-time { font-size: 11px; color: var(--g400); flex-shrink: 0; }
.wa-conv-time.unread { color: var(--green); font-weight: 600; }
.wa-conv-last { font-size: 12px; color: var(--g600); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wa-conv-sub { font-size: 11px; color: var(--g400); margin-top: 2px; }
.wa-unread { background: var(--green); color: #fff; border-radius: 10px; font-size: 10.5px; font-weight: 700; min-width: 18px; padding: 1px 6px; text-align: center; flex-shrink: 0; }
.wa-placeholder { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; color: var(--g500); font-size: 13px; }
.wa-chat-head { display: flex; gap: 10px; align-items: flex-start; padding: 12px 16px; border-bottom: 1px solid var(--g200); }
.wa-back { display: none; }
.wa-chat-name { font-weight: 700; font-size: 14px; color: var(--g900); }
.wa-chat-sub { font-size: 11.5px; color: var(--g500); margin-top: 2px; }
.wa-patients { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
.wa-patients a { text-decoration: none; }
.wa-thread { flex: 1; overflow-y: auto; padding: 14px 16px; background: #efeae2; }
.wa-day { text-align: center; margin: 10px 0; }
.wa-day span { background: #fff; color: var(--g500); font-size: 11px; padding: 3px 10px; border-radius: 8px; box-shadow: var(--shadow-sm); }
.wa-tpl { text-align: center; font-size: 11.5px; color: var(--g600); background: #fdf6dc; border-radius: 8px; padding: 5px 10px; margin: 6px auto; width: fit-content; max-width: 90%; }
.wa-row { display: flex; margin: 4px 0; }
.wa-row.out { justify-content: flex-end; }
.wa-bubble { max-width: 70%; padding: 6px 9px 4px; border-radius: 8px; box-shadow: var(--shadow-sm); font-size: 13px; }
.wa-bubble.in { background: #fff; }
.wa-bubble.out { background: #d9fdd3; }
.wa-text { white-space: pre-wrap; word-break: break-word; color: var(--g900); }
.wa-meta { font-size: 10.5px; color: var(--g400); text-align: right; margin-top: 2px; display: flex; justify-content: flex-end; align-items: center; gap: 3px; }
.wa-quote { border-left: 3px solid var(--green); background: rgba(0,0,0,.04); padding: 3px 6px; border-radius: 4px; font-size: 11.5px; color: var(--g600); margin-bottom: 4px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.wa-img { max-width: 260px; max-height: 260px; border-radius: 6px; display: block; margin-bottom: 4px; }
.wa-fail { font-size: 11px; color: var(--red); margin-top: 2px; }
.wa-replybtn { border: 0; background: transparent; color: var(--g400); cursor: pointer; padding: 0 0 0 4px; font-size: 13px; }
.wa-replybtn:hover { color: var(--g700); }
.wa-compose { border-top: 1px solid var(--g200); padding: 10px 14px; }
.wa-compose-row { display: flex; gap: 8px; align-items: flex-end; }
.wa-compose-row textarea { flex: 1; resize: vertical; min-height: 44px; }
.wa-window { font-size: 11px; color: var(--g400); margin-top: 4px; }
.wa-replying { display: flex; justify-content: space-between; align-items: center; background: var(--g50); border-left: 3px solid var(--green); padding: 4px 8px; border-radius: 4px; font-size: 12px; color: var(--g600); margin-bottom: 6px; }
@media (max-width: 860px) {
  .wa-wrap { grid-template-columns: 1fr; height: calc(100vh - 100px); }
  .wa-wrap.has-sel .wa-list { display: none; }
  .wa-wrap:not(.has-sel) .wa-chat { display: none; }
  .wa-back { display: inline-flex; }
  .wa-bubble { max-width: 85%; }
}
`;
