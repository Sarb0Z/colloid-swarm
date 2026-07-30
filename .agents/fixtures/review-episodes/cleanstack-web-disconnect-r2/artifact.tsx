'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase, API_URL } from '@/lib/supabase';
import { useEscapeKey } from '@/hooks/use-escape-key';
import type { ConnectionStatus, BannerMessage } from '@/types/connect';

// The Google Workspace connect card. Reads the current connection status (RLS-scoped,
// so only this org's row is visible) and starts the OAuth flow via the API. The API
// returns the consent URL as JSON so the Bearer token never leaves the browser's
// control and org resolution stays server-side.
export default function ConnectPage() {
  const [status, setStatus] = useState<ConnectionStatus>('loading');
  const [connectedAt, setConnectedAt] = useState<string | null>(null);
  const [banner, setBanner] = useState<BannerMessage | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [disconnecting, setDisconnecting] = useState(false);
  // Disconnect is one click to undo but costs a full admin re-consent to redo, so it
  // arms first and acts second.
  const [confirmingDisconnect, setConfirmingDisconnect] = useState(false);

  const cancelBtn = useRef<HTMLButtonElement>(null);
  const disconnectBtn = useRef<HTMLButtonElement>(null);
  const primaryBtn = useRef<HTMLButtonElement>(null);
  const wasArmed = useRef(false);

  // Arming swaps the buttons out from under the keyboard, so focus has to be carried
  // across by hand or it falls to <body>. Cancel takes it on the way in — never the
  // destructive button, which a held Enter would fire. On the way out the trigger is
  // gone once the disconnect succeeds, so fall through to the primary button.
  useEffect(() => {
    if (confirmingDisconnect) {
      cancelBtn.current?.focus();
    } else if (wasArmed.current) {
      (disconnectBtn.current ?? primaryBtn.current)?.focus();
    }
    wasArmed.current = confirmingDisconnect;
  }, [confirmingDisconnect]);

  useEscapeKey(confirmingDisconnect && !disconnecting, () =>
    setConfirmingDisconnect(false),
  );

  const loadStatus = useCallback(async () => {
    const { data, error } = await supabase
      .from('integrations')
      .select('status, connected_at')
      .eq('provider', 'google')
      .maybeSingle();

    if (error) {
      // Don't assert "not connected" on a transient read failure — leave the prior
      // state and let the user retry.
      return;
    }
    if (data?.status === 'connected') {
      setStatus('connected');
      setConnectedAt(data.connected_at);
    } else {
      setStatus('disconnected');
    }
  }, []);

  useEffect(() => {
    // The callback redirects back here with ?connected=1 or ?error=1. Show a banner,
    // then strip the param so a refresh doesn't repeat it.
    const params = new URLSearchParams(window.location.search);
    if (params.get('connected') === '1') {
      setBanner({ kind: 'ok', msg: 'Google Workspace connected. You can run an audit.' });
    } else if (params.get('error') === '1') {
      setBanner({
        kind: 'err',
        msg: 'Could not connect Google Workspace. Make sure you approved access as a Workspace admin, then try again.',
      });
    }
    if (params.has('connected') || params.has('error')) {
      window.history.replaceState({}, '', '/dashboard/connect');
    }
    void loadStatus();
  }, [loadStatus]);

  async function connect() {
    setConnecting(true);
    setBanner(null);
    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) throw new Error('Your session expired. Please sign in again.');

      const res = await fetch(`${API_URL}/api/auth/google`, {
        headers: { Authorization: `Bearer ${session.access_token}` },
      });
      if (!res.ok) throw new Error('Could not start the Google connect flow. Please try again.');

      const { url } = (await res.json()) as { url?: string };
      if (!url) throw new Error('Could not start the Google connect flow. Please try again.');
      // Hand the browser to Google's consent screen.
      window.location.href = url;
    } catch (err) {
      setBanner({
        kind: 'err',
        msg: err instanceof Error ? err.message : 'Something went wrong.',
      });
      setConnecting(false);
    }
  }

  // Hands the grant back to Google and forgets the tokens. Nothing else is touched, so
  // the card returns to a clean pre-connect state ready for a fresh consent.
  async function disconnect() {
    setDisconnecting(true);
    setBanner(null);
    try {
      const {
        data: { session },
      } = await supabase.auth.getSession();
      if (!session) throw new Error('Your session expired. Please sign in again.');

      // Bounded: the route revokes at Google before it answers, and both buttons are
      // dead until it does. Without a deadline a hung revoke freezes the card for good.
      const res = await fetch(`${API_URL}/api/auth/google/disconnect`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${session.access_token}` },
        signal: AbortSignal.timeout(20_000),
      }).catch(() => {
        throw new Error('Could not reach CleanStack. Check your connection and try again.');
      });
      // The route is throttled; "try again" is the one thing that won't work on a 429.
      if (res.status === 429) {
        throw new Error('Too many attempts. Wait a minute, then try again.');
      }
      if (!res.ok) throw new Error('Could not disconnect Google Workspace. Please try again.');

      setStatus('disconnected');
      setConnectedAt(null);
      setBanner({
        kind: 'ok',
        msg: 'Google Workspace disconnected. Your audits and tool data are unchanged.',
      });
    } catch (err) {
      setBanner({
        kind: 'err',
        msg: err instanceof Error ? err.message : 'Something went wrong.',
      });
    } finally {
      setDisconnecting(false);
      setConfirmingDisconnect(false);
    }
  }

  const isConnected = status === 'connected';
  const footnote = confirmingDisconnect
    ? 'This revokes access at Google. Audits and tool data are kept.'
    : isConnected && connectedAt
      ? `Connected ${new Date(connectedAt).toLocaleDateString()}`
      : 'The person who connects must be a Google Workspace admin.';

  return (
    <div className="rise" style={{ maxWidth: 620 }}>
      <p className="kicker" style={{ marginBottom: 12 }}>
        Integrations
      </p>
      <h1 style={{ fontSize: '2rem', marginBottom: 10 }}>Connect your stack</h1>
      <p style={{ color: 'var(--ink-muted)', marginBottom: 28, maxWidth: '52ch' }}>
        CleanStack reads your Google Workspace directory and third-party app grants —
        strictly read-only — to find the seats and accounts you&rsquo;re paying for but
        nobody uses.
      </p>

      {banner && (
        <div
          className={`banner ${banner.kind === 'ok' ? 'banner--ok' : 'banner--err'}`}
          style={{ marginBottom: 20 }}
        >
          {banner.msg}
        </div>
      )}

      <div className="card" style={{ padding: 26 }}>
        <div
          style={{
            display: 'flex',
            alignItems: 'flex-start',
            justifyContent: 'space-between',
            gap: 20,
          }}
        >
          <div style={{ display: 'flex', gap: 16 }}>
            <GoogleGlyph />
            <div>
              <h2 style={{ fontSize: '1.2rem', marginBottom: 4 }}>Google Workspace</h2>
              <p style={{ fontSize: '0.9rem', color: 'var(--ink-muted)' }}>
                Directory + third-party app usage
              </p>
            </div>
          </div>
          <StatusPill status={status} />
        </div>

        <hr className="rule" style={{ margin: '22px 0' }} />

        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 16,
            flexWrap: 'wrap',
          }}
        >
          <p
            id="connect-footnote"
            className="mono"
            role="status"
            style={{
              fontSize: '0.78rem',
              color: confirmingDisconnect ? 'var(--red)' : 'var(--ink-faint)',
              maxWidth: '40ch',
              // The confirm swap widens the buttons; let the note give up width instead
              // of bumping them onto a second row, which reads as the card lurching.
              // Basis 0, not auto: wrapping is decided on the base size, so an `auto`
              // basis measures the full sentence and breaks the row before it shrinks.
              flex: '1 1 0%',
              minWidth: 0,
            }}
          >
            {footnote}
          </p>
          <div style={{ display: 'flex', gap: 10, flexShrink: 0 }}>
            {confirmingDisconnect ? (
              <>
                <button
                  ref={cancelBtn}
                  type="button"
                  className="btn btn--ghost"
                  onClick={() => setConfirmingDisconnect(false)}
                  disabled={disconnecting}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="btn btn--danger"
                  onClick={disconnect}
                  disabled={disconnecting}
                  aria-describedby="connect-footnote"
                >
                  {disconnecting ? 'Disconnecting…' : 'Confirm disconnect'}
                </button>
              </>
            ) : (
              <>
                {isConnected && (
                  <button
                    ref={disconnectBtn}
                    type="button"
                    className="btn btn--ghost"
                    onClick={() => {
                      setBanner(null);
                      setConfirmingDisconnect(true);
                    }}
                    disabled={connecting}
                  >
                    Disconnect
                  </button>
                )}
                <button
                  ref={primaryBtn}
                  type="button"
                  className="btn"
                  onClick={connect}
                  disabled={connecting || status === 'loading'}
                >
                  {connecting
                    ? 'Redirecting…'
                    : isConnected
                      ? 'Reconnect'
                      : 'Connect Google Workspace'}
                </button>
              </>
            )}
          </div>
        </div>
      </div>

      <p
        style={{
          marginTop: 18,
          fontSize: '0.82rem',
          color: 'var(--ink-muted)',
          display: 'flex',
          gap: 8,
          alignItems: 'center',
        }}
      >
        <LockGlyph />
        Read-only access. We never request permission to change anything in your
        Workspace.
      </p>
    </div>
  );
}

function StatusPill({ status }: { status: ConnectionStatus }) {
  const map = {
    loading: { label: 'Checking…', color: 'var(--ink-faint)', bg: 'var(--surface-2)' },
    connected: { label: 'Connected', color: 'var(--pine)', bg: 'var(--pine-wash)' },
    disconnected: { label: 'Not connected', color: 'var(--amber)', bg: 'var(--amber-wash)' },
  }[status];

  return (
    <span
      className="mono"
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 7,
        padding: '5px 11px',
        borderRadius: 999,
        fontSize: '0.72rem',
        fontWeight: 500,
        color: map.color,
        background: map.bg,
        whiteSpace: 'nowrap',
      }}
    >
      <span
        style={{
          width: 7,
          height: 7,
          borderRadius: 999,
          background: map.color,
          display: 'inline-block',
        }}
      />
      {map.label}
    </span>
  );
}

// Small inline glyphs so the page needs no image assets.
function GoogleGlyph() {
  return (
    <div
      aria-hidden
      style={{
        width: 44,
        height: 44,
        borderRadius: 11,
        background: 'var(--surface-2)',
        display: 'grid',
        placeItems: 'center',
        flexShrink: 0,
        fontFamily: 'var(--font-mono), monospace',
        fontWeight: 600,
        color: 'var(--pine)',
        fontSize: '1.1rem',
      }}
    >
      G
    </div>
  );
}

function LockGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" aria-hidden>
      <rect x="4" y="10" width="16" height="11" rx="2" stroke="var(--pine)" strokeWidth="2" />
      <path d="M8 10V7a4 4 0 0 1 8 0v3" stroke="var(--pine)" strokeWidth="2" />
    </svg>
  );
}

