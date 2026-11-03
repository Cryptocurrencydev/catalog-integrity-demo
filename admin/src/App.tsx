import { useCallback, useEffect, useState, type FormEvent } from "react";
import type { Session } from "@supabase/supabase-js";
import { DEMO_EMAIL, DEMO_PASSWORD } from "./config";
import { supabase } from "./supabase";
import { explainError, ToastProvider } from "./ui";
import { QueuePage } from "./pages/Queue";
import { DraftsPage } from "./pages/Drafts";
import { QualityPage } from "./pages/Quality";
import { AuditPage } from "./pages/Audit";
import { IngestPage } from "./pages/Ingest";

const TABS = [
  ["queue", "Verification queue"],
  ["drafts", "Repair drafts"],
  ["quality", "Data quality"],
  ["audit", "Audit log"],
  ["ingest", "Ingest"],
] as const;
type Tab = (typeof TABS)[number][0];

const tabFromHash = (): Tab => {
  const h = window.location.hash.replace("#", "") as Tab;
  return TABS.some(([t]) => t === h) ? h : "queue";
};

function Footer() {
  return (
    <footer className="foot">
      <div>
        <span>Inciva is a fictional brand. All products, brands and ingredient lists are synthetic.</span>
        <span>Demo by <a href="https://dctechltd.com" target="_blank" rel="noopener">DC Tech</a></span>
      </div>
    </footer>
  );
}

function Login() {
  const [email, setEmail] = useState(DEMO_EMAIL);
  const [password, setPassword] = useState(DEMO_PASSWORD);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) setError(explainError(error));
    setBusy(false);
  }
  return (
    <div className="shell">
      <main>
        <form className="card login" onSubmit={submit}>
          <div className="brand"><img src="/favicon.svg" alt="" /> Inciva <small>catalog integrity</small></div>
          <h1>Admin sign-in</h1>
          <p>Demo admin credentials are pre-filled. Data is synthetic and the queue tops itself up nightly, so approve, reject and resolve freely.</p>
          <label>Email<input className="input" type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          <label>Password<input className="input" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
          {error && <div className="error">{error}</div>}
          <button className="btn primary" disabled={busy} type="submit" style={{ justifyContent: "center" }}>{busy ? "Signing in…" : "Sign in as demo admin"}</button>
        </form>
      </main>
      <Footer />
    </div>
  );
}

export default function App() {
  const [session, setSession] = useState<Session | null | undefined>(undefined);
  const [tab, setTab] = useState<Tab>(tabFromHash);
  const [counts, setCounts] = useState<{ queue?: number; drafts?: number }>({});

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    const onHash = () => setTab(tabFromHash());
    window.addEventListener("hashchange", onHash);
    return () => {
      data.subscription.unsubscribe();
      window.removeEventListener("hashchange", onHash);
    };
  }, []);

  const refreshCounts = useCallback(async () => {
    const [q, d] = await Promise.all([
      supabase.from("verification_queue").select("id", { count: "exact", head: true }).eq("status", "pending"),
      supabase.from("repair_drafts").select("id", { count: "exact", head: true }).eq("status", "pending"),
    ]);
    setCounts({ queue: q.count ?? undefined, drafts: d.count ?? undefined });
  }, []);
  useEffect(() => {
    if (session) refreshCounts();
  }, [session, refreshCounts]);

  if (session === undefined) return null;
  if (!session) return <ToastProvider><Login /></ToastProvider>;

  const isAdmin = session.user.app_metadata?.role === "admin";
  const go = (t: Tab) => {
    window.location.hash = t;
    setTab(t);
  };

  return (
    <ToastProvider>
      <div className="shell">
        <header className="topbar">
          <div className="topbar-inner">
            <div className="brandrow">
              <div className="brand"><img src="/favicon.svg" alt="" /> Inciva <small>catalog integrity</small></div>
              <div className="who">
                <span className="email">{session.user.email}</span>
                <button className="btn sm" onClick={() => supabase.auth.signOut()}>Sign out</button>
              </div>
            </div>
            <nav className="tabs" aria-label="Sections">
              {TABS.map(([t, label]) => (
                <button key={t} className="tab" aria-current={tab === t ? "page" : undefined} onClick={() => go(t)}>
                  {label}
                  {t === "queue" && counts.queue != null && <span className="count">{counts.queue.toLocaleString("en-GB")}</span>}
                  {t === "drafts" && counts.drafts != null && <span className="count">{counts.drafts}</span>}
                </button>
              ))}
            </nav>
          </div>
        </header>
        <main>
          {!isAdmin && <div className="error">This account is not an admin. RLS returns no queue, draft or audit rows for it.</div>}
          {tab === "queue" && <QueuePage onChanged={refreshCounts} />}
          {tab === "drafts" && <DraftsPage onChanged={refreshCounts} />}
          {tab === "quality" && <QualityPage />}
          {tab === "audit" && <AuditPage />}
          {tab === "ingest" && <IngestPage onChanged={refreshCounts} />}
        </main>
        <Footer />
      </div>
    </ToastProvider>
  );
}
