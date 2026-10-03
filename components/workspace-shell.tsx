"use client";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import type { Workspace } from "@/components/retail-flow-app";
import { PlatformAdministration } from "@/components/platform-administration";
import { InventoryManagement } from "@/components/inventory-management";
import { PointOfSale } from "@/components/point-of-sale";
import { PurchasingWorkspace } from "@/components/purchasing-workspace";
import { InventoryOperations } from "@/components/inventory-operations";
import { ReturnsWorkspace } from "@/components/returns-workspace";
import { supabase } from "@/lib/supabase/client";

type Membership = Workspace["memberships"][number];
type Page = "dashboard" | "pos" | "returns" | "inventory" | "operations" | "purchasing" | "branches" | "staff" | "settings" | "platform";
type AdminData = {
  organization: {
    id: string; name: string; slug: string; business_address: string | null;
    phone: string | null; email: string | null; website: string | null;
    receipt_footer: string | null; enabled_modules: Record<string, boolean>;
  };
  branches: Array<{ id: string; name: string; code: string; active: boolean }>;
  members: Array<{
    membership_id: string; user_id: string; email: string; full_name: string | null;
    role: string; active: boolean; branch_ids: string[]; branch_names: string[];
  }>;
  invitations: Array<{ id: string; token: string; email: string; role: string; branch_ids: string[]; status: string; expires_at: string }>;
};

const navItems: Array<{ id: Page; label: string; icon: string }> = [
  { id: "dashboard", label: "Dashboard", icon: "▦" },
  { id: "pos", label: "Point of Sale", icon: "▣" },
  { id: "returns", label: "Returns & Refunds", icon: "↩" },
  { id: "inventory", label: "Products & Inventory", icon: "▤" },
  { id: "operations", label: "Inventory Operations", icon: "⇄" },
  { id: "purchasing", label: "Purchasing", icon: "▥" },
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
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

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
  const isOrganizationAdmin = membership.role === "owner" || membership.role === "administrator";
  const canManageInventory = isOrganizationAdmin || membership.role === "manager";
  const visibleBranches = isOrganizationAdmin || isPlatformAdministrator ? (data?.branches ?? membership.branches) : membership.branches;
  const visibleNav = navItems.filter((item) => {
    if (item.id === "pos") return data?.organization.enabled_modules.pos !== false;
    if (item.id === "returns") return canManageInventory && data?.organization.enabled_modules.pos !== false;
    if (item.id === "inventory") return canManageInventory && data?.organization.enabled_modules.products !== false && data?.organization.enabled_modules.inventory !== false;
    if (item.id === "operations") return canManageInventory && data?.organization.enabled_modules.inventory !== false;
    if (item.id === "purchasing") return canManageInventory && data?.organization.enabled_modules.purchasing !== false;
    if (["branches", "staff", "settings"].includes(item.id)) return isOrganizationAdmin;
    return true;
  });

  return (
    <main className="workspaceLayout">
      <header className="mobileTopbar">
        <div className="mobileBrandMark">RF</div>
        <div className="mobileIdentity"><strong>{branch?.name ?? membership.organization_name}</strong><span>{membership.organization_name}</span></div>
        <span className="mobileOnline" aria-label="Online" />
        <button className="mobileMenuButton" onClick={() => setMobileMenuOpen(true)} aria-label="Open navigation">☰</button>
      </header>
      {mobileMenuOpen && <button className="mobileMenuBackdrop" aria-label="Close navigation" onClick={() => setMobileMenuOpen(false)} />}
      <aside className={`sidebar ${mobileMenuOpen ? "mobileOpen" : ""}`}>
        <button className="mobileMenuClose" onClick={() => setMobileMenuOpen(false)} aria-label="Close navigation">×</button>
        <div className="brand sidebarBrand">RetailFlow</div>
        <div className="organizationIdentity">
          <strong>{membership.organization_name}</strong>
          <span>{membership.role}</span>
        </div>
        <nav>
          {visibleNav.map((item) => <button key={item.id} className={page === item.id ? "active" : ""} onClick={() => { setPage(item.id); setMobileMenuOpen(false); }}><span>{item.icon}</span>{item.label}</button>)}
          {isPlatformAdministrator && <button className={page === "platform" ? "active" : ""} onClick={() => { setPage("platform"); setMobileMenuOpen(false); }}><span>◇</span>Platform Administration</button>}
        </nav>
        <div className="sidebarFooter"><span>{email}</span><button onClick={onSignOut}>Sign out</button></div>
      </aside>
      <section className="workspaceMain">
        <header className="workspaceHeader">
          <div><p className="eyebrow">{membership.organization_name}</p><h1>{titleFor(page)}</h1></div>
          <label className="branchSelector">Active branch<select value={branchId} onChange={(event) => setBranchId(event.target.value)}>{visibleBranches.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
        </header>
        {error && <div className="formError pageMessage">{error} <button onClick={load}>Retry</button></div>}
        {loading && <div className="contentLoading">Loading workspace…</div>}
        {!loading && data && page === "dashboard" && <Dashboard data={data} branchName={branch?.name ?? "Main Branch"} />}
        {!loading && data && page === "pos" && <PointOfSale organizationId={data.organization.id} branchId={branchId} branchName={branch?.name ?? "Branch"} canVoid={canManageInventory} />}
        {!loading && data && page === "returns" && <ReturnsWorkspace organizationId={data.organization.id} branchId={branchId} />}
        {!loading && data && page === "inventory" && <InventoryManagement organizationId={data.organization.id} branches={data.branches} />}
        {!loading && data && page === "operations" && <InventoryOperations organizationId={data.organization.id} branches={data.branches.filter((item) => item.active)} />}
        {!loading && data && page === "purchasing" && <PurchasingWorkspace organizationId={data.organization.id} branchId={branchId} />}
        {!loading && data && page === "branches" && <Branches data={data} onChanged={async () => { await load(); await onWorkspaceRefresh(); }} />}
        {!loading && data && page === "staff" && <Staff data={data} onChanged={load} />}
        {!loading && data && page === "settings" && <Settings organization={data.organization} onChanged={async () => { await load(); await onWorkspaceRefresh(); }} />}
        {!loading && page === "platform" && <PlatformAdministration />}
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

function Staff({ data, onChanged }: { data: AdminData; onChanged: () => Promise<void> }) {
  const [open, setOpen] = useState(false); const [busy, setBusy] = useState(false); const [error, setError] = useState(""); const [message, setMessage] = useState("");
  async function invite(event: FormEvent<HTMLFormElement>) { event.preventDefault(); setBusy(true); setError(""); setMessage(""); const form=new FormData(event.currentTarget); const branchIds=form.getAll("branches").map(String); const { data: token,error:rpcError }=await supabase.rpc("create_organization_invitation",{p_organization_id:data.organization.id,p_email:String(form.get("email")),p_role:String(form.get("role")),p_branch_ids:branchIds}); if(rpcError)setError(rpcError.message); else { const link=`${window.location.origin}/?invite=${token}`; await navigator.clipboard.writeText(link); setMessage("Invitation created and link copied to your clipboard."); setOpen(false); await onChanged(); } setBusy(false); }
  async function revoke(id:string){setBusy(true);setError("");const{error:rpcError}=await supabase.rpc("revoke_organization_invitation",{p_invitation_id:id});if(rpcError)setError(rpcError.message);else await onChanged();setBusy(false);}
  async function copy(token:string){await navigator.clipboard.writeText(`${window.location.origin}/?invite=${token}`);setMessage("Invitation link copied.");}
  return <div className="contentStack"><div className="sectionActions"><p>Invite staff, assign roles, and control branch access.</p><button className="primaryButton compact" onClick={()=>setOpen(!open)}>{open?"Cancel":"Invite staff"}</button></div>{error&&<div className="formError">{error}</div>}{message&&<div className="formSuccess">{message}</div>}{open&&<form className="inviteForm" onSubmit={invite}><div className="formGrid"><label>Email<input name="email" type="email" required /></label><label>Role<select name="role" defaultValue="staff"><option value="administrator">Administrator</option><option value="manager">Manager</option><option value="cashier">Cashier</option><option value="staff">Staff</option></select></label></div><fieldset><legend>Branch access</legend><div className="moduleGrid">{data.branches.filter(b=>b.active).map(branch=><label key={branch.id}><input type="checkbox" name="branches" value={branch.id}/>{branch.name}</label>)}</div></fieldset><button className="primaryButton compact" disabled={busy}>{busy?"Creating…":"Create invitation link"}</button></form>}<div className="tableWrap"><table><thead><tr><th>Staff member</th><th>Role</th><th>Branches</th><th>Status</th></tr></thead><tbody>{data.members.map((member) => <tr key={member.membership_id}><td><strong>{member.full_name || member.email}</strong><small>{member.full_name ? member.email : ""}</small></td><td className="capitalize">{member.role}</td><td>{member.branch_names.join(", ") || "No branch"}</td><td><span className={member.active ? "statusPill" : "statusPill inactive"}>{member.active ? "Active" : "Inactive"}</span></td></tr>)}</tbody></table></div>{data.invitations.length>0&&<section className="adminCard"><div className="sectionActions"><div><h2>Pending invitations</h2><p>Invitation links expire after seven days.</p></div></div><div className="tableWrap"><table><thead><tr><th>Email</th><th>Role</th><th>Expires</th><th>Actions</th></tr></thead><tbody>{data.invitations.map(item=><tr key={item.id}><td>{item.email}</td><td className="capitalize">{item.role}</td><td>{new Date(item.expires_at).toLocaleDateString()}</td><td><div className="rowActions"><button className="tableAction" onClick={()=>void copy(item.token)}>Copy link</button><button className="tableAction danger" disabled={busy} onClick={()=>void revoke(item.id)}>Revoke</button></div></td></tr>)}</tbody></table></div></section>}</div>;
}

function Settings({ organization, onChanged }: { organization: AdminData["organization"]; onChanged: () => Promise<void> }) {
  const [busy, setBusy] = useState(false); const [message, setMessage] = useState(""); const [error, setError] = useState("");
  async function submit(event: FormEvent<HTMLFormElement>) { event.preventDefault(); setBusy(true); setMessage(""); setError(""); const form = new FormData(event.currentTarget); const { error: rpcError } = await supabase.rpc("update_organization_business_profile", { p_organization_id: organization.id, p_name: String(form.get("name")), p_address: String(form.get("address")), p_phone: String(form.get("phone")), p_email: String(form.get("email")), p_website: String(form.get("website")), p_receipt_footer: String(form.get("receiptFooter")) }); if (rpcError) setError(rpcError.message); else { setMessage("Organization settings saved."); await onChanged(); } setBusy(false); }
  return <form className="settingsForm" onSubmit={submit}><div className="formGrid"><label>Organization name<input name="name" required defaultValue={organization.name} /></label><label>Organization code<input disabled value={organization.slug} /></label><label>Business email<input name="email" type="email" defaultValue={organization.email ?? ""} /></label><label>Phone<input name="phone" defaultValue={organization.phone ?? ""} /></label><label className="fullWidth">Business address<input name="address" defaultValue={organization.business_address ?? ""} /></label><label>Website<input name="website" type="url" defaultValue={organization.website ?? ""} /></label><label>Receipt footer<input name="receiptFooter" defaultValue={organization.receipt_footer ?? ""} /></label></div>{error && <div className="formError">{error}</div>}{message && <div className="formSuccess">{message}</div>}<button className="primaryButton compact" disabled={busy}>{busy ? "Saving…" : "Save settings"}</button></form>;
}

function titleFor(page: Page) { return ({ dashboard: "Dashboard", pos: "Point of Sale", returns: "Returns & Refunds", inventory: "Products & Inventory", operations: "Inventory Operations", purchasing: "Purchasing", branches: "Branches", staff: "Staff Access", settings: "Organization Settings", platform: "Platform Administration" } as const)[page]; }
