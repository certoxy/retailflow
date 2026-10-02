"use client";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import type { Workspace } from "@/components/retail-flow-app";
import { supabase } from "@/lib/supabase/client";

type Membership = Workspace["memberships"][number];
type Page = "dashboard" | "branches" | "staff" | "settings" | "platform";
type AdminData = {
  organization: {
    id: string; name: string; slug: string; business_address: string | null;
    phone: string | null; email: string | null; website: string | null;
    receipt_footer: string | null;
  };
  branches: Array<{ id: string; name: string; code: string; active: boolean }>;
  members: Array<{
    membership_id: string; user_id: string; email: string; full_name: string | null;
    role: string; active: boolean; branch_names: string[];
  }>;
};

const navItems: Array<{ id: Page; label: string; icon: string }> = [
  { id: "dashboard", label: "Dashboard", icon: "▦" },
  { id: "branches", label: "Branches", icon: "⌂" },
  { id: "staff", label: "Staff Access", icon: "◎" },
  { id: "settings", label: "Organization Settings", icon: "⚙" },
];

export function WorkspaceShell({
  email, membership, isPlatformAdministrator, onSignOut, onWorkspaceRefresh,
}: {
  email: string;
  membership: Membership;
  isPlatformAdministrator: boolean;
  onSignOut: () => void;
  onWorkspaceRefresh: () => Promise<void>;
}) {
  const [page, setPage] = useState<Page>("dashboard");
  const [data, setData] = useState<AdminData | null>(null);
  const [branchId, setBranchId] = useState(membership.branches[0]?.id ?? "");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    setLoading(true); setError("");
    const { data: response, error: responseError } = await supabase.rpc(
      "get_organization_admin_data", { p_organization_id: membership.organization_id },
    );
    if (responseError) setError(responseError.message);
    else setData(response as AdminData);
    setLoading(false);
  }, [membership.organization_id]);

  useEffect(() => { void load(); }, [load]);
  const branch = useMemo(() => data?.branches.find((item) => item.id === branchId), [data, branchId]);

  return (
    <main className="workspaceLayout">
      <aside className="sidebar">
        <div className="brand sidebarBrand">RetailFlow</div>
        <div className="organizationIdentity">
          <strong>{membership.organization_name}</strong>
          <span>{membership.role}</span>
        </div>
        <nav>
          {navItems.map((item) => <button key={item.id} className={page === item.id ? "active" : ""} onClick={() => setPage(item.id)}><span>{item.icon}</span>{item.label}</button>)}
          {isPlatformAdministrator && <button className={page === "platform" ? "active" : ""} onClick={() => setPage("platform")}><span>◇</span>Platform Administration</button>}
        </nav>
        <div className="sidebarFooter"><span>{email}</span><button onClick={onSignOut}>Sign out</button></div>
      </aside>
      <section className="workspaceMain">
        <header className="workspaceHeader">
          <div><p className="eyebrow">{membership.organization_name}</p><h1>{titleFor(page)}</h1></div>
          <label className="branchSelector">Active branch<select value={branchId} onChange={(event) => setBranchId(event.target.value)}>{(data?.branches ?? membership.branches).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
        </header>
        {error && <div className="formError pageMessage">{error} <button onClick={load}>Retry</button></div>}
        {loading && <div className="contentLoading">Loading workspace…</div>}
        {!loading && data && page === "dashboard" && <Dashboard data={data} branchName={branch?.name ?? "Main Branch"} />}
        {!loading && data && page === "branches" && <Branches data={data} onChanged={async () => { await load(); await onWorkspaceRefresh(); }} />}
        {!loading && data && page === "staff" && <Staff members={data.members} />}
        {!loading && data && page === "settings" && <Settings organization={data.organization} onChanged={async () => { await load(); await onWorkspaceRefresh(); }} />}
        {!loading && page === "platform" && <EmptyState title="Platform Administration" message="The platform workspace is connected. Organization controls, plan limits, and feature entitlements are the next platform administration checkpoint." />}
      </section>
    </main>
  );
}

function Dashboard({ data, branchName }: { data: AdminData; branchName: string }) {
  const cards = [
    ["Active branch", branchName], ["Branches", String(data.branches.filter((b) => b.active).length)],
    ["Active staff", String(data.members.filter((m) => m.active).length)], ["Today’s sales", "Coming next"],
  ];
  return <div className="dashboardGrid">{cards.map(([label, value]) => <article className="metricCard" key={label}><span>{label}</span><strong>{value}</strong></article>)}<article className="welcomeCard"><p className="eyebrow">Workspace ready</p><h2>Your RetailFlow administration foundation is active.</h2><p>Manage organization information, branches, and staff access here. Products, inventory, and point of sale will follow in controlled releases.</p></article></div>;
}

function Branches({ data, onChanged }: { data: AdminData; onChanged: () => Promise<void> }) {
  const [open, setOpen] = useState(false); const [busy, setBusy] = useState(false); const [error, setError] = useState("");
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setBusy(true); setError(""); const form = new FormData(event.currentTarget);
    const { error: rpcError } = await supabase.rpc("create_organization_branch", { p_organization_id: data.organization.id, p_name: String(form.get("name")), p_code: String(form.get("code")).toUpperCase() });
    if (rpcError) setError(rpcError.message); else { setOpen(false); await onChanged(); }
    setBusy(false);
  }
  return <div className="contentStack"><div className="sectionActions"><p>Manage locations operating under this organization.</p><button className="primaryButton compact" onClick={() => setOpen(!open)}>{open ? "Cancel" : "Add branch"}</button></div>{open && <form className="inlineForm" onSubmit={submit}><label>Branch name<input name="name" required /></label><label>Branch code<input name="code" required maxLength={12} pattern="[A-Za-z0-9-]+" /></label>{error && <div className="formError">{error}</div>}<button className="primaryButton" disabled={busy}>{busy ? "Adding…" : "Create branch"}</button></form>}<div className="dataCards">{data.branches.map((branch) => <article key={branch.id}><div><strong>{branch.name}</strong><span>{branch.code}</span></div><span className={branch.active ? "statusPill" : "statusPill inactive"}>{branch.active ? "Active" : "Inactive"}</span></article>)}</div></div>;
}

function Staff({ members }: { members: AdminData["members"] }) {
  return <div className="contentStack"><div className="sectionActions"><p>Review organization roles and assigned branches.</p><button className="secondaryButton" disabled>Invite staff · Next checkpoint</button></div><div className="tableWrap"><table><thead><tr><th>Staff member</th><th>Role</th><th>Branches</th><th>Status</th></tr></thead><tbody>{members.map((member) => <tr key={member.membership_id}><td><strong>{member.full_name || member.email}</strong><small>{member.full_name ? member.email : ""}</small></td><td className="capitalize">{member.role}</td><td>{member.branch_names.join(", ") || "No branch"}</td><td><span className={member.active ? "statusPill" : "statusPill inactive"}>{member.active ? "Active" : "Inactive"}</span></td></tr>)}</tbody></table></div></div>;
}

function Settings({ organization, onChanged }: { organization: AdminData["organization"]; onChanged: () => Promise<void> }) {
  const [busy, setBusy] = useState(false); const [message, setMessage] = useState(""); const [error, setError] = useState("");
  async function submit(event: FormEvent<HTMLFormElement>) { event.preventDefault(); setBusy(true); setMessage(""); setError(""); const form = new FormData(event.currentTarget); const { error: rpcError } = await supabase.rpc("update_organization_business_profile", { p_organization_id: organization.id, p_name: String(form.get("name")), p_address: String(form.get("address")), p_phone: String(form.get("phone")), p_email: String(form.get("email")), p_website: String(form.get("website")), p_receipt_footer: String(form.get("receiptFooter")) }); if (rpcError) setError(rpcError.message); else { setMessage("Organization settings saved."); await onChanged(); } setBusy(false); }
  return <form className="settingsForm" onSubmit={submit}><div className="formGrid"><label>Organization name<input name="name" required defaultValue={organization.name} /></label><label>Organization code<input disabled value={organization.slug} /></label><label>Business email<input name="email" type="email" defaultValue={organization.email ?? ""} /></label><label>Phone<input name="phone" defaultValue={organization.phone ?? ""} /></label><label className="fullWidth">Business address<input name="address" defaultValue={organization.business_address ?? ""} /></label><label>Website<input name="website" type="url" defaultValue={organization.website ?? ""} /></label><label>Receipt footer<input name="receiptFooter" defaultValue={organization.receipt_footer ?? ""} /></label></div>{error && <div className="formError">{error}</div>}{message && <div className="formSuccess">{message}</div>}<button className="primaryButton compact" disabled={busy}>{busy ? "Saving…" : "Save settings"}</button></form>;
}

function EmptyState({ title, message }: { title: string; message: string }) { return <section className="emptyState"><div>◇</div><h2>{title}</h2><p>{message}</p></section>; }
function titleFor(page: Page) { return ({ dashboard: "Dashboard", branches: "Branches", staff: "Staff Access", settings: "Organization Settings", platform: "Platform Administration" } as const)[page]; }
