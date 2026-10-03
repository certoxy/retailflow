"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";

const moduleLabels: Record<string, string> = {
  dashboard: "Dashboard", branches: "Branches", staff: "Staff Access",
  products: "Products", inventory: "Inventory", pos: "Point of Sale",
  purchasing: "Purchasing", expenses: "Expenses", reports: "Reports",
};

type PlatformData = {
  organizations: Array<{
    id: string; name: string; slug: string; active: boolean; user_limit: number;
    member_count: number; branch_count: number; enabled_modules: Record<string, boolean>;
    created_at: string;
  }>;
  platform_administrators: Array<{
    user_id: string; email: string; full_name: string | null; active: boolean;
    created_at: string; has_organization_membership: boolean;
  }>;
};

export function PlatformAdministration() {
  const [data, setData] = useState<PlatformData | null>(null);
  const [selectedId, setSelectedId] = useState("");
  const [showGrant, setShowGrant] = useState(false);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");

  const load = useCallback(async () => {
    setLoading(true); setError("");
    const { data: result, error: rpcError } = await supabase.rpc("get_platform_admin_dashboard");
    if (rpcError) setError(rpcError.message);
    else {
      const next = result as PlatformData;
      setData(next);
      setSelectedId((current) => current || next.organizations[0]?.id || "");
    }
    setLoading(false);
  }, []);

  useEffect(() => { void load(); }, [load]);
  const selected = data?.organizations.find((organization) => organization.id === selectedId);

  async function saveOrganization(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!selected) return;
    setBusy(true); setError(""); setMessage("");
    const form = new FormData(event.currentTarget);
    const enabledModules = Object.fromEntries(Object.keys(moduleLabels).map((key) => [key, form.get(`module-${key}`) === "on"]));
    const { error: rpcError } = await supabase.rpc("update_platform_organization_controls", {
      p_organization_id: selected.id,
      p_active: form.get("active") === "on",
      p_user_limit: Number(form.get("userLimit")),
      p_enabled_modules: enabledModules,
    });
    if (rpcError) setError(rpcError.message);
    else { setMessage(`${selected.name} controls saved.`); await load(); }
    setBusy(false);
  }

  async function grant(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setError(""); setMessage("");
    const form = new FormData(event.currentTarget);
    const { error: rpcError } = await supabase.rpc("grant_platform_administrator", { p_email: String(form.get("email") ?? "").trim() });
    if (rpcError) setError(rpcError.message);
    else { setMessage("Platform Administrator access granted."); setShowGrant(false); await load(); }
    setBusy(false);
  }

  async function setAdminActive(userId: string, active: boolean) {
    setBusy(true); setError(""); setMessage("");
    const { error: rpcError } = await supabase.rpc("set_platform_administrator_active", { p_user_id: userId, p_active: active });
    if (rpcError) setError(rpcError.message);
    else { setMessage(`Platform Administrator ${active ? "activated" : "deactivated"}.`); await load(); }
    setBusy(false);
  }

  if (loading) return <div className="contentLoading">Loading platform administration…</div>;
  if (!data) return <div className="formError pageMessage">{error || "Platform data unavailable."} <button onClick={load}>Retry</button></div>;

  return <div className="contentStack platformWorkspace">
    <div className="platformSummary">
      <article className="metricCard"><span>Organizations</span><strong>{data.organizations.length}</strong></article>
      <article className="metricCard"><span>Active organizations</span><strong>{data.organizations.filter((item) => item.active).length}</strong></article>
      <article className="metricCard"><span>Platform admins</span><strong>{data.platform_administrators.filter((item) => item.active).length}</strong></article>
    </div>
    {error && <div className="formError">{error}</div>}
    {message && <div className="formSuccess">{message}</div>}

    <section className="adminCard">
      <div className="sectionActions"><div><h2>Organizations</h2><p>Control access, user limits, and enabled RetailFlow modules.</p></div></div>
      <div className="platformSplit">
        <div className="organizationList">{data.organizations.map((organization) => <button key={organization.id} className={selectedId === organization.id ? "selected" : ""} onClick={() => { setSelectedId(organization.id); setMessage(""); setError(""); }}><span><strong>{organization.name}</strong><small>{organization.member_count} of {organization.user_limit} users · {organization.branch_count} branches</small></span><span className={organization.active ? "statusPill" : "statusPill inactive"}>{organization.active ? "Active" : "Suspended"}</span></button>)}</div>
        {selected && <form className="organizationControls" key={selected.id} onSubmit={saveOrganization}>
          <div className="controlHeader"><div><h3>{selected.name}</h3><small>{selected.slug}</small></div><label className="toggleLabel"><input type="checkbox" name="active" defaultChecked={selected.active} />Organization active</label></div>
          <label>User limit<input name="userLimit" type="number" min="1" max="10000" required defaultValue={selected.user_limit} /><small>{selected.member_count} active user{selected.member_count === 1 ? "" : "s"} currently consume seats.</small></label>
          <fieldset><legend>Enabled modules</legend><div className="moduleGrid">{Object.entries(moduleLabels).map(([key, label]) => <label key={key}><input type="checkbox" name={`module-${key}`} defaultChecked={selected.enabled_modules[key] !== false} />{label}</label>)}</div></fieldset>
          <button className="primaryButton compact" disabled={busy}>{busy ? "Saving…" : "Save organization controls"}</button>
        </form>}
      </div>
    </section>

    <section className="adminCard">
      <div className="sectionActions"><div><h2>Platform Administrators</h2><p>Platform-only accounts do not require organization membership.</p></div><button className="primaryButton compact" onClick={() => setShowGrant(!showGrant)}>{showGrant ? "Cancel" : "Add Platform Administrator"}</button></div>
      {showGrant && <form className="inlineForm adminGrantForm" onSubmit={grant}><label>User email<input name="email" type="email" required placeholder="admin@example.com" /><small>The user must already have a RetailFlow account.</small></label><button className="primaryButton" disabled={busy}>{busy ? "Granting…" : "Grant access"}</button></form>}
      <div className="tableWrap"><table><thead><tr><th>Administrator</th><th>Scope</th><th>Status</th><th>Action</th></tr></thead><tbody>{data.platform_administrators.map((administrator) => <tr key={administrator.user_id}><td><strong>{administrator.full_name || administrator.email}</strong><small>{administrator.full_name ? administrator.email : ""}</small></td><td>{administrator.has_organization_membership ? "Platform + organization" : "Platform only"}</td><td><span className={administrator.active ? "statusPill" : "statusPill inactive"}>{administrator.active ? "Active" : "Inactive"}</span></td><td><button className="tableAction" disabled={busy} onClick={() => void setAdminActive(administrator.user_id, !administrator.active)}>{administrator.active ? "Deactivate" : "Activate"}</button></td></tr>)}</tbody></table></div>
    </section>
  </div>;
}
