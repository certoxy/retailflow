import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const resendApiKey = Deno.env.get("RESEND_API_KEY")!;
const cronSecret = Deno.env.get("TRIAL_REMINDER_CRON_SECRET")!;
const appUrl = Deno.env.get("APP_URL") ?? "https://retail.paotechs.com";
const supportEmail = "hello@paotechs.com";
const fromEmail = "RetailFlow <noreply@send.paotechs.com>";
const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

type Organization = { id: string; name: string; trial_ends_at: string };
type TrialNotificationType = "trial_10_day" | "trial_expired";

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const body = await request.json().catch(() => ({}));
    if (body.action === "upgrade-request") return await sendUpgradeRequest(request, body.organizationId);
    if (body.action === "send-trial-reminders") return await sendTrialReminders(request);
    return json({ error: "Unsupported action" }, 400);
  } catch (error) {
    console.error(error);
    return json({ error: error instanceof Error ? error.message : "Unexpected error" }, 500);
  }
});

async function sendUpgradeRequest(request: Request, organizationId: string) {
  const token = request.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token || !organizationId) return json({ error: "Authentication required" }, 401);
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData.user) return json({ error: "Authentication required" }, 401);

  const { data: membership } = await admin.from("organization_memberships")
    .select("role, organizations(name, business_address, phone, subscription_plan, subscription_status, trial_ends_at)")
    .eq("organization_id", organizationId).eq("user_id", userData.user.id).eq("active", true).maybeSingle();
  if (!membership) return json({ error: "Organization access required" }, 403);

  const organization = membership.organizations as unknown as {
    name: string; business_address: string | null; phone: string | null;
    subscription_plan: string; subscription_status: string; trial_ends_at: string | null;
  };
  if (!organization.phone?.trim()) return json({ error: "A contact phone is required in Organization Settings before requesting an upgrade." }, 422);

  const { data: owners, error: ownerError } = await admin.from("organization_memberships")
    .select("profiles(full_name,email)").eq("organization_id", organizationId).eq("role", "owner").eq("active", true);
  if (ownerError) throw ownerError;
  const ownerContacts = (owners ?? []).map((item) => item.profiles as unknown as { full_name: string | null; email: string } | null).filter(Boolean) as Array<{ full_name: string | null; email: string }>;
  const requesterName = String(userData.user.user_metadata?.full_name ?? userData.user.email ?? "RetailFlow user");
  const ownerNames = ownerContacts.length ? ownerContacts.map((owner) => owner.full_name || "Name not provided").join(", ") : requesterName;
  const ownerEmails = ownerContacts.length ? ownerContacts.map((owner) => owner.email).join(", ") : (userData.user.email ?? "Not provided");
  const subject = `RetailFlow upgrade request — ${organization.name}`;
  const text = [
    `A RetailFlow plan upgrade was requested by ${requesterName} (${userData.user.email}).`,
    `Organization: ${organization.name}`,
    `Owner: ${ownerNames}`,
    `Owner email: ${ownerEmails}`,
    `Contact phone: ${organization.phone}`,
    `Business address: ${organization.business_address ?? "Not provided"}`,
    `Current plan: ${organization.subscription_plan}`,
    `Subscription status: ${organization.subscription_status}`,
    `Trial ends: ${organization.trial_ends_at ? formatDate(organization.trial_ends_at) : "Not set"}`,
  ].join("\n");
  const html = emailLayout(subject, `<h1>RetailFlow upgrade request</h1><p><strong>${escapeHtml(requesterName)}</strong> (${escapeHtml(userData.user.email ?? "")}) requested a plan upgrade.</p><p><strong>Organization:</strong> ${escapeHtml(organization.name)}<br><strong>Owner:</strong> ${escapeHtml(ownerNames)}<br><strong>Owner email:</strong> ${escapeHtml(ownerEmails)}<br><strong>Contact phone:</strong> ${escapeHtml(organization.phone)}<br><strong>Business address:</strong> ${escapeHtml(organization.business_address ?? "Not provided")}<br><strong>Current plan:</strong> ${escapeHtml(organization.subscription_plan)}<br><strong>Status:</strong> ${escapeHtml(organization.subscription_status)}<br><strong>Trial ends:</strong> ${organization.trial_ends_at ? escapeHtml(formatDate(organization.trial_ends_at)) : "Not set"}</p>`);

  const result = await sendEmail({ to: [supportEmail], replyTo: userData.user.email ?? supportEmail, subject, html, text }, `upgrade-${organizationId}-${userData.user.id}`);
  return json({ sent: true, id: result.id });
}

async function sendTrialReminders(request: Request) {
  if (!cronSecret || request.headers.get("x-cron-secret") !== cronSecret) return json({ error: "Invalid scheduler credential" }, 401);
  const now = new Date();
  const limit = new Date(now.getTime() + 10 * 86400000);
  const startOfToday = new Date(now.getTime() - 24 * 60 * 60 * 1000);
  const { data: organizations, error } = await admin.from("organizations").select("id,name,trial_ends_at")
    .eq("active", true).eq("subscription_status", "trial").gte("trial_ends_at", startOfToday.toISOString()).lte("trial_ends_at", limit.toISOString());
  if (error) throw error;

  const results = [];
  for (const organization of (organizations ?? []) as Organization[]) {
    const daysRemaining = calendarDaysBetween(now, new Date(organization.trial_ends_at));
    if (daysRemaining === 0) results.push(await notifyOrganization(organization, "trial_expired", 0));
    else if (daysRemaining >= 1 && daysRemaining <= 10) results.push(await notifyOrganization(organization, "trial_10_day", daysRemaining));
  }
  return json({ processed: results.length, results });
}

async function notifyOrganization(organization: Organization, notificationType: TrialNotificationType, days: number) {
  const { data: existing } = await admin.from("subscription_notification_log").select("id,status")
    .eq("organization_id", organization.id).eq("notification_type", notificationType).eq("trial_ends_at", organization.trial_ends_at).maybeSingle();
  if (existing?.status === "sent") return { organizationId: organization.id, notificationType, status: "already_sent" };

  const { data: memberships, error: membershipError } = await admin.from("organization_memberships")
    .select("profiles(email)").eq("organization_id", organization.id).eq("active", true).in("role", ["owner", "administrator"]);
  if (membershipError) throw membershipError;
  const recipients = [...new Set((memberships ?? []).map((item) => (item.profiles as unknown as { email: string } | null)?.email).filter(Boolean))] as string[];
  if (!recipients.length) return { organizationId: organization.id, notificationType, status: "no_admin_email" };

  const row = { organization_id: organization.id, notification_type: notificationType, trial_ends_at: organization.trial_ends_at, recipients, cc_recipients: [supportEmail], status: "pending", error_message: null, updated_at: new Date().toISOString() };
  const { error: logError } = await admin.from("subscription_notification_log").upsert(row, { onConflict: "organization_id,notification_type,trial_ends_at" });
  if (logError) throw logError;

  const expired = notificationType === "trial_expired";
  const subject = expired ? `Your RetailFlow free trial has expired` : `${days} days remaining in your RetailFlow free trial`;
  const text = expired
    ? `The RetailFlow free trial for ${organization.name} expired on ${formatDate(organization.trial_ends_at)}. Contact the App Administrator at ${supportEmail} to continue using RetailFlow. Open RetailFlow: ${appUrl}`
    : `Your RetailFlow free trial for ${organization.name} ends on ${formatDate(organization.trial_ends_at)}. Contact the App Administrator at ${supportEmail} to continue using RetailFlow. Open RetailFlow: ${appUrl}`;
  const html = expired
    ? emailLayout(subject, `<h1>Your RetailFlow trial has expired</h1><p>The free trial for <strong>${escapeHtml(organization.name)}</strong> expired on <strong>${escapeHtml(formatDate(organization.trial_ends_at))}</strong>.</p><p>Contact the App Administrator at <a href="mailto:${supportEmail}">${supportEmail}</a> to choose a plan and continue using RetailFlow.</p><p><a class="button" href="${appUrl}">Open RetailFlow</a></p>`)
    : emailLayout(subject, `<h1>Your RetailFlow trial ends soon</h1><p><strong>${days} days remain</strong> in the free trial for ${escapeHtml(organization.name)}.</p><p>Your trial ends on <strong>${escapeHtml(formatDate(organization.trial_ends_at))}</strong>. Contact the App Administrator at <a href="mailto:${supportEmail}">${supportEmail}</a> to choose a plan and continue using RetailFlow.</p><p><a class="button" href="${appUrl}">Open RetailFlow</a></p>`);

  try {
    const sent = await sendEmail({ to: recipients, cc: [supportEmail], replyTo: supportEmail, subject, html, text }, `${notificationType}-${organization.id}-${organization.trial_ends_at}`);
    await admin.from("subscription_notification_log").update({ status: "sent", provider_message_id: sent.id, sent_at: new Date().toISOString(), error_message: null, updated_at: new Date().toISOString() }).eq("organization_id", organization.id).eq("notification_type", notificationType).eq("trial_ends_at", organization.trial_ends_at);
    return { organizationId: organization.id, notificationType, status: "sent" };
  } catch (error) {
    await admin.from("subscription_notification_log").update({ status: "failed", error_message: error instanceof Error ? error.message : "Send failed", updated_at: new Date().toISOString() }).eq("organization_id", organization.id).eq("notification_type", notificationType).eq("trial_ends_at", organization.trial_ends_at);
    return { organizationId: organization.id, notificationType, status: "failed" };
  }
}

async function sendEmail(payload: { to: string[]; cc?: string[]; replyTo: string; subject: string; html: string; text: string }, idempotencyKey: string) {
  const response = await fetch("https://api.resend.com/emails", { method: "POST", headers: { "Authorization": `Bearer ${resendApiKey}`, "Content-Type": "application/json", "Idempotency-Key": idempotencyKey }, body: JSON.stringify({ from: fromEmail, to: payload.to, cc: payload.cc, reply_to: payload.replyTo, subject: payload.subject, html: payload.html, text: payload.text }) });
  const result = await response.json();
  if (!response.ok) throw new Error(result.message ?? `Email service returned ${response.status}`);
  return result as { id: string };
}

function emailLayout(title: string, content: string) {
  return `<!doctype html><html lang="en" dir="ltr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${escapeHtml(title)}</title></head><body style="margin:0;background:#f3f7f6;color:#173c42;font-family:Arial,sans-serif"><div lang="en" dir="ltr" style="max-width:600px;margin:0 auto;padding:28px 18px"><div style="background:#fff;border:1px solid #d4e3e0;border-radius:16px;padding:28px"><p style="margin:0 0 18px;color:#147c7a;font-weight:700">RetailFlow by PAOTechs</p>${content}<p style="margin:26px 0 0;color:#61777b;font-size:14px">Questions? Reply to this email or contact <a href="mailto:${supportEmail}" style="color:#0d706f">${supportEmail}</a>.</p></div></div><style>.button{display:inline-block;min-height:44px;line-height:44px;padding:0 20px;border-radius:9px;background:#0d706f;color:#fff!important;text-decoration:none;font-weight:700}h1{font-size:24px;line-height:1.25}p{font-size:16px;line-height:1.55}</style></body></html>`;
}

function formatDate(value: string) { return new Intl.DateTimeFormat("en-PH", { dateStyle: "long", timeZone: "Asia/Manila" }).format(new Date(value)); }
function calendarDaysBetween(from: Date, to: Date) {
  const formatter = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Manila", year: "numeric", month: "2-digit", day: "2-digit" });
  const toUtcDay = (date: Date) => {
    const parts = Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
    return Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day));
  };
  return Math.round((toUtcDay(to) - toUtcDay(from)) / 86400000);
}
function escapeHtml(value: string) { return value.replace(/[&<>'"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[char]!); }
function json(body: unknown, status = 200) { return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
