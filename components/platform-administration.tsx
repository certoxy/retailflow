"use client";

import { FormEvent, useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";

const moduleLabels: Record<string, string> = {
  dashboard: "Dashboard", branches: "Branches", staff: "Staff Access",
  products: "Products", inventory: "Inventory", pos: "Point of Sale",
  returns:"Returns & Refunds",operations:"Inventory Operations",purchasing: "Purchasing", expenses: "Expenses", reports: "Reports",
};

type PlatformData = {
  organizations: Array<{
    id: string; name: string; slug: string; active: boolean; user_limit: number;
    member_count: number; branch_count: number; branch_limit:number; enabled_modules: Record<string, boolean>;
    subscription_plan:string;billing_cycle:string;subscription_status:string;trial_ends_at:string|null;
    next_billing_at:string|null;subscription_price:number|null;
    product_count:number;archived_product_count:number;customer_count:number;archived_customer_count:number;
    sales_30d_count:number;sales_30d_total:number;purchases_30d_count:number;purchases_30d_total:number;
    last_sale_at:string|null;
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
  const money = (value:number) => new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP",maximumFractionDigits:0}).format(value);
  const percent = (used:number,limit:number) => Math.min(100,Math.round((used/Math.max(1,limit))*100));

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

  async function saveSubscription(event:FormEvent<HTMLFormElement>){event.preventDefault();if(!selected)return;setBusy(true);setError("");setMessage("");const form=new FormData(event.currentTarget);const{error:rpcError}=await supabase.rpc("update_platform_organization_subscription",{p_organization_id:selected.id,p_plan:String(form.get("plan")),p_billing_cycle:String(form.get("billingCycle")),p_status:String(form.get("subscriptionStatus")),p_trial_ends_at:form.get("trialEndsAt")?new Date(String(form.get("trialEndsAt"))).toISOString():null,p_next_billing_at:form.get("nextBillingAt")?new Date(String(form.get("nextBillingAt"))).toISOString():null,p_subscription_price:form.get("subscriptionPrice")===""?null:Number(form.get("subscriptionPrice"))});if(rpcError)setError(rpcError.message);else{setMessage(`${selected.name} subscription saved.`);await load();}setBusy(false);}

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
        <div className="organizationList">{data.organizations.map((organization) => <button key={organization.id} className={selectedId === organization.id ? "selected" : ""} onClick={() => { setSelectedId(organization.id); setMessage(""); setError(""); }}><span><strong>{organization.name}</strong><small>{organization.member_count}/{organization.user_limit} users · {organization.branch_count}/{organization.branch_limit} branches</small><small className="capitalize">{organization.subscription_plan} · {organization.subscription_status.replace("_"," ")}</small></span><span className={organization.active ? "statusPill" : "statusPill inactive"}>{organization.active ? "Active" : "Suspended"}</span></button>)}</div>
        {selected && <div className="organizationControls" key={selected.id}><section className="usageMonitor"><div className="controlHeader"><div><h3>Organization usage</h3><small>Current resources and activity for {selected.name}</small></div><button type="button" className="tableAction" onClick={() => void load()} disabled={loading}>Refresh</button></div><div className="usageLimits"><UsageBar label="User seats" used={selected.member_count??0} limit={selected.user_limit??1} percent={percent(selected.member_count??0,selected.user_limit??1)}/><UsageBar label="Branches" used={selected.branch_count??0} limit={selected.branch_limit??1} percent={percent(selected.branch_count??0,selected.branch_limit??1)}/></div><div className="usageMetrics"><UsageMetric label="Active products" value={(selected.product_count??0).toLocaleString()} note={`${(selected.archived_product_count??0).toLocaleString()} archived`}/><UsageMetric label="Active customers" value={(selected.customer_count??0).toLocaleString()} note={`${(selected.archived_customer_count??0).toLocaleString()} archived`}/><UsageMetric label="Sales · 30 days" value={money(selected.sales_30d_total??0)} note={`${(selected.sales_30d_count??0).toLocaleString()} completed orders`}/><UsageMetric label="Purchases · 30 days" value={money(selected.purchases_30d_total??0)} note={`${(selected.purchases_30d_count??0).toLocaleString()} purchase orders`}/></div><p className="usageActivity">Last completed sale: <strong>{selected.last_sale_at?new Date(selected.last_sale_at).toLocaleString():"No completed sales yet"}</strong></p></section><form className="subscriptionForm" onSubmit={saveSubscription}><div className="controlHeader"><div><h3>{selected.name}</h3><small>Subscription and billing</small></div><span className={`statusPill ${selected.subscription_status==="past_due"?"warning":selected.subscription_status==="active"||selected.subscription_status==="trial"?"":"inactive"}`}>{selected.subscription_status.replace("_"," ")}</span></div><div className="formGrid"><label>Plan<select name="plan" defaultValue={selected.subscription_plan}><option value="starter">Starter — ₱799/mo</option><option value="growth">Growth — ₱1,499/mo</option><option value="business">Business — ₱2,999/mo</option><option value="enterprise">Enterprise — Custom</option></select></label><label>Billing cycle<select name="billingCycle" defaultValue={selected.billing_cycle}><option value="monthly">Monthly</option><option value="annual">Annual</option><option value="complimentary">Complimentary</option></select></label><label>Status<select name="subscriptionStatus" defaultValue={selected.subscription_status}><option value="trial">Trial</option><option value="active">Active</option><option value="past_due">Past due</option><option value="suspended">Suspended</option><option value="cancelled">Cancelled</option></select></label><label>Agreed price<input name="subscriptionPrice" type="number" min="0" step="0.01" defaultValue={selected.subscription_price??""} placeholder="Plan price"/></label><label>Trial ends<input name="trialEndsAt" type="date" defaultValue={selected.trial_ends_at?.slice(0,10)??""}/></label><label>Next billing date<input name="nextBillingAt" type="date" defaultValue={selected.next_billing_at?.slice(0,10)??""}/></label></div><button className="primaryButton compact" disabled={busy}>{busy?"Saving…":"Save subscription"}</button></form><form className="manualControls" onSubmit={saveOrganization}>
          <div className="controlHeader"><div><h3>{selected.name}</h3><small>{selected.slug}</small></div><label className="toggleLabel"><input type="checkbox" name="active" defaultChecked={selected.active} />Organization active</label></div>
          <label>User limit<input name="userLimit" type="number" min="1" max="10000" required defaultValue={selected.user_limit} /><small>{selected.member_count} active user{selected.member_count === 1 ? "" : "s"} currently consume seats.</small></label>
          <fieldset><legend>Enabled modules</legend><div className="moduleGrid">{Object.entries(moduleLabels).map(([key, label]) => <label key={key}><input type="checkbox" name={`module-${key}`} defaultChecked={selected.enabled_modules[key] !== false} />{label}</label>)}</div></fieldset>
          <button className="secondaryButton" disabled={busy}>{busy ? "Saving…" : "Save manual overrides"}</button>
        </form></div>}
      </div>
    </section>

    <section className="adminCard">
      <div className="sectionActions"><div><h2>Platform Administrators</h2><p>Platform-only accounts do not require organization membership.</p></div><button className="primaryButton compact" onClick={() => setShowGrant(!showGrant)}>{showGrant ? "Cancel" : "Add Platform Administrator"}</button></div>
      {showGrant && <form className="inlineForm adminGrantForm" onSubmit={grant}><label>User email<input name="email" type="email" required placeholder="admin@example.com" /><small>The user must already have a RetailFlow account.</small></label><button className="primaryButton" disabled={busy}>{busy ? "Granting…" : "Grant access"}</button></form>}
      <div className="tableWrap"><table><thead><tr><th>Administrator</th><th>Scope</th><th>Status</th><th>Action</th></tr></thead><tbody>{data.platform_administrators.map((administrator) => <tr key={administrator.user_id}><td><strong>{administrator.full_name || administrator.email}</strong><small>{administrator.full_name ? administrator.email : ""}</small></td><td>{administrator.has_organization_membership ? "Platform + organization" : "Platform only"}</td><td><span className={administrator.active ? "statusPill" : "statusPill inactive"}>{administrator.active ? "Active" : "Inactive"}</span></td><td><button className="tableAction" disabled={busy} onClick={() => void setAdminActive(administrator.user_id, !administrator.active)}>{administrator.active ? "Deactivate" : "Activate"}</button></td></tr>)}</tbody></table></div>
    </section>
  </div>;
}

function UsageBar({label,used,limit,percent}:{label:string;used:number;limit:number;percent:number}){const level=percent>=100?"critical":percent>=80?"warning":"";return <div className="usageBar"><div><strong>{label}</strong><span>{used.toLocaleString()} of {limit.toLocaleString()} · {percent}%</span></div><div className="usageTrack"><i className={level} style={{width:`${percent}%`}}/></div></div>}
function UsageMetric({label,value,note}:{label:string;value:string;note:string}){return <article><span>{label}</span><strong>{value}</strong><small>{note}</small></article>}
