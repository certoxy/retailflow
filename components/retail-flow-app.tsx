"use client";

import type { Session } from "@supabase/supabase-js";
import { FormEvent, useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";
import { WorkspaceShell } from "@/components/workspace-shell";
import { PlatformAdministration } from "@/components/platform-administration";

export type Workspace = {
  profile: { email: string; full_name: string | null } | null;
  is_platform_administrator: boolean;
  memberships: Array<{
    membership_id: string;
    role: string;
    organization_id: string;
    organization_name: string;
    organization_slug: string;
    branches: Array<{ id: string; name: string; code: string }>;
  }>;
};

const emptyWorkspace: Workspace = {
  profile: null,
  is_platform_administrator: false,
  memberships: [],
};

export function RetailFlowApp() {
  const [session, setSession] = useState<Session | null>(null);
  const [workspace, setWorkspace] = useState<Workspace>(emptyWorkspace);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const loadWorkspace = useCallback(async () => {
    setLoading(true);
    setError("");
    const { data, error: workspaceError } = await supabase.rpc("get_my_workspace");
    if (workspaceError) {
      setError(workspaceError.message);
      setWorkspace(emptyWorkspace);
    } else {
      setWorkspace((data as Workspace) ?? emptyWorkspace);
    }
    setLoading(false);
  }, []);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      if (data.session) void loadWorkspace();
      else setLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
      if (next) void loadWorkspace();
      else {
        setWorkspace(emptyWorkspace);
        setLoading(false);
      }
    });

    return () => listener.subscription.unsubscribe();
  }, [loadWorkspace]);

  if (loading) return <LoadingScreen />;
  if (!session) return <AuthScreen />;

  if (error) {
    return (
      <AppShell email={session.user.email} onSignOut={() => supabase.auth.signOut()}>
        <Notice title="Workspace unavailable" message={error} onRetry={loadWorkspace} />
      </AppShell>
    );
  }

  if (workspace.is_platform_administrator && workspace.memberships.length === 0) {
    return (
      <AppShell email={workspace.profile?.email} onSignOut={() => supabase.auth.signOut()}>
        <section className="standalonePlatform">
          <div className="standalonePlatformHeader"><p className="eyebrow">Platform administration</p><h1>RetailFlow platform workspace</h1></div>
          <PlatformAdministration />
        </section>
      </AppShell>
    );
  }

  if (workspace.memberships.length === 0) {
    return (
      <AppShell email={workspace.profile?.email} onSignOut={() => supabase.auth.signOut()}>
        <OrganizationOnboarding onCreated={loadWorkspace} />
      </AppShell>
    );
  }

  return <WorkspaceShell
    email={workspace.profile?.email ?? session.user.email ?? ""}
    membership={workspace.memberships[0]}
    isPlatformAdministrator={workspace.is_platform_administrator}
    onSignOut={() => supabase.auth.signOut()}
    onWorkspaceRefresh={loadWorkspace}
  />;
}

function AuthScreen() {
  const [mode, setMode] = useState<"signin" | "signup">("signin");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");
    const values = new FormData(event.currentTarget);
    const email = String(values.get("email") ?? "").trim();
    const password = String(values.get("password") ?? "");
    const fullName = String(values.get("fullName") ?? "").trim();

    const result = mode === "signin"
      ? await supabase.auth.signInWithPassword({ email, password })
      : await supabase.auth.signUp({
          email,
          password,
          options: { data: { full_name: fullName } },
        });

    if (result.error) setError(result.error.message);
    else if (mode === "signup" && !result.data.session) {
      setMessage("Account created. Check your email to confirm your address, then sign in.");
    }
    setBusy(false);
  }

  return (
    <main className="authPage">
      <section className="authIntro">
        <div className="brand">RetailFlow</div>
        <p className="eyebrow">PAOTechs retail operations platform</p>
        <h1>Sales and inventory, built to flow.</h1>
        <p className="summary">One secure workspace for organizations, branches, staff, products, stock, and daily sales.</p>
      </section>
      <section className="authCard">
        <div className="modeTabs" role="tablist">
          <button className={mode === "signin" ? "active" : ""} onClick={() => setMode("signin")}>Sign in</button>
          <button className={mode === "signup" ? "active" : ""} onClick={() => setMode("signup")}>Create account</button>
        </div>
        <h2>{mode === "signin" ? "Welcome back" : "Start with RetailFlow"}</h2>
        <p>{mode === "signin" ? "Sign in to continue to your workspace." : "Create the owner account for a new retail organization."}</p>
        <form onSubmit={submit}>
          {mode === "signup" && <label>Full name<input name="fullName" required autoComplete="name" /></label>}
          <label>Email<input name="email" type="email" required autoComplete="email" /></label>
          <label>Password<input name="password" type="password" minLength={8} required autoComplete={mode === "signin" ? "current-password" : "new-password"} /></label>
          {error && <div className="formError">{error}</div>}
          {message && <div className="formSuccess">{message}</div>}
          <button className="primaryButton" disabled={busy}>{busy ? "Please wait…" : mode === "signin" ? "Sign in" : "Create account"}</button>
        </form>
      </section>
    </main>
  );
}

function OrganizationOnboarding({ onCreated }: { onCreated: () => Promise<void> }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    const values = new FormData(event.currentTarget);
    const name = String(values.get("name") ?? "").trim();
    const slug = String(values.get("slug") ?? "").trim().toLowerCase();
    const branchName = String(values.get("branchName") ?? "Main Branch").trim();
    const { error: createError } = await supabase.rpc("create_organization_with_branch", {
      p_name: name,
      p_slug: slug,
      p_branch_name: branchName,
    });
    if (createError) setError(createError.message);
    else await onCreated();
    setBusy(false);
  }

  return (
    <section className="panel onboardingPanel">
      <p className="eyebrow">Organization onboarding</p>
      <h1>Create your retail workspace</h1>
      <p className="summary">Your organization is securely separated from every other RetailFlow business. We’ll also create its first branch.</p>
      <form onSubmit={submit} className="onboardingForm">
        <label>Organization name<input name="name" required placeholder="Example Retail Store" /></label>
        <label>Organization URL code<input name="slug" required pattern="[a-z0-9]+(?:-[a-z0-9]+)*" placeholder="example-retail-store" /><small>Lowercase letters, numbers, and hyphens only.</small></label>
        <label>First branch name<input name="branchName" required defaultValue="Main Branch" /></label>
        {error && <div className="formError">{error}</div>}
        <button className="primaryButton" disabled={busy}>{busy ? "Creating workspace…" : "Create organization"}</button>
      </form>
    </section>
  );
}

function AppShell({ children, email, onSignOut }: { children: React.ReactNode; email?: string; onSignOut: () => void }) {
  return <main className="appPage"><header><div className="brand">RetailFlow</div><div className="account"><span>{email}</span><button onClick={onSignOut}>Sign out</button></div></header>{children}</main>;
}

function DashboardCard({ eyebrow, title, message }: { eyebrow: string; title: string; message: string }) {
  return <section className="panel"><p className="eyebrow">{eyebrow}</p><h1>{title}</h1><p className="summary">{message}</p><div className="status"><span className="statusDot" />Workspace active</div></section>;
}

function Notice({ title, message, onRetry }: { title: string; message: string; onRetry: () => void }) {
  return <section className="panel"><h1>{title}</h1><p className="summary">{message}</p><button className="primaryButton" onClick={onRetry}>Try again</button></section>;
}

function LoadingScreen() {
  return <main className="loadingPage"><div className="brand">RetailFlow</div><p>Loading your workspace…</p></main>;
}
