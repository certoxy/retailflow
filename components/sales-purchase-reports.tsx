"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabase/client";

type Range = "daily" | "weekly" | "quarterly" | "yearly" | "custom";
type Report = {
  summary: { sales_total:number; sales_count:number; purchases_total:number; purchase_count:number };
  daily: Array<{date:string;sales:number;purchases:number;sales_count:number;purchase_count:number}>;
  sales: Array<{id:string;number:string;date:string;customer:string;total:number;status:string}>;
  purchases: Array<{id:string;number:string;date:string;supplier:string;total:number;status:string}>;
};

const iso=(date:Date)=>date.toISOString().slice(0,10);
function datesFor(range:Exclude<Range,"custom">){
  const end=new Date();const start=new Date(end);
  if(range==="weekly")start.setDate(end.getDate()-6);
  if(range==="quarterly"){start.setMonth(Math.floor(end.getMonth()/3)*3,1);}
  if(range==="yearly")start.setMonth(0,1);
  return {start:iso(start),end:iso(end)};
}
const money=(value:number)=>new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"}).format(Number(value));
const xml=(value:unknown)=>String(value??"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
const textCell=(value:unknown)=>`<Cell><Data ss:Type="String">${xml(value)}</Data></Cell>`;
const numberCell=(value:unknown)=>`<Cell ss:StyleID="Currency"><Data ss:Type="Number">${Number(value)||0}</Data></Cell>`;

export function SalesPurchaseReports({organizationId,branchId}:{organizationId:string;branchId:string}){
  const[range,setRange]=useState<Range>("daily");const initial=datesFor("daily");const[start,setStart]=useState(initial.start);const[end,setEnd]=useState(initial.end);const[report,setReport]=useState<Report|null>(null);const[loading,setLoading]=useState(true);const[error,setError]=useState("");
  const load=useCallback(async(from:string,to:string)=>{if(!branchId)return;setLoading(true);setError("");const{data,error:rpcError}=await supabase.rpc("get_sales_purchase_report",{p_organization_id:organizationId,p_branch_id:branchId,p_start_date:from,p_end_date:to});if(rpcError)setError(rpcError.message);else setReport(data as Report);setLoading(false);},[organizationId,branchId]);
  useEffect(()=>{void load(start,end);},[load,start,end]);
  function selectRange(next:Range){setRange(next);if(next!=="custom"){const dates=datesFor(next);setStart(dates.start);setEnd(dates.end);}}
  function exportExcel(){if(!report)return;const summaryRows=[
    ["Report period",`${start} to ${end}`],["Sales",report.summary.sales_total],["Completed orders",report.summary.sales_count],["Purchases",report.summary.purchases_total],["Purchase orders",report.summary.purchase_count],["Sales less purchases",report.summary.sales_total-report.summary.purchases_total],
  ].map(([label,value])=>`<Row>${textCell(label)}${typeof value==="number"?numberCell(value):textCell(value)}</Row>`).join("");
    const salesRows=report.sales.map(row=>`<Row>${textCell(row.number)}${textCell(new Date(row.date).toLocaleString())}${textCell(row.customer)}${numberCell(row.total)}${textCell(row.status)}</Row>`).join("");
    const purchaseRows=report.purchases.map(row=>`<Row>${textCell(row.number)}${textCell(new Date(row.date).toLocaleString())}${textCell(row.supplier)}${numberCell(row.total)}${textCell(row.status)}</Row>`).join("");
    const workbook=`<?xml version="1.0"?><Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet"><Styles><Style ss:ID="Header"><Font ss:Bold="1"/><Interior ss:Color="#DDF3F0" ss:Pattern="Solid"/></Style><Style ss:ID="Currency"><NumberFormat ss:Format="₱#,##0.00"/></Style></Styles><Worksheet ss:Name="Summary"><Table><Row ss:StyleID="Header">${textCell("Metric")}${textCell("Value")}</Row>${summaryRows}</Table></Worksheet><Worksheet ss:Name="Sales"><Table><Row ss:StyleID="Header">${["Receipt","Date","Customer","Total","Status"].map(textCell).join("")}</Row>${salesRows}</Table></Worksheet><Worksheet ss:Name="Purchases"><Table><Row ss:StyleID="Header">${["PO Number","Date","Supplier","Total","Status"].map(textCell).join("")}</Row>${purchaseRows}</Table></Worksheet></Workbook>`;
    const url=URL.createObjectURL(new Blob([workbook],{type:"application/vnd.ms-excel;charset=utf-8"}));const link=document.createElement("a");link.href=url;link.download=`RetailFlow_Report_${start}_to_${end}.xls`;link.click();URL.revokeObjectURL(url);
  }
  const max=useMemo(()=>Math.max(1,...(report?.daily??[]).flatMap(row=>[Number(row.sales),Number(row.purchases)])),[report]);
  const summary=report?.summary;
  return <div className="contentStack reportWorkspace">
    <section className="reportControls"><div className="modeTabs reportTabs">{(["daily","weekly","quarterly","yearly","custom"] as Range[]).map(item=><button key={item} className={range===item?"active":""} onClick={()=>selectRange(item)}>{item[0].toUpperCase()+item.slice(1)}</button>)}</div><div className="reportControlActions">{range==="custom"&&<div className="customDates"><label>From<input type="date" value={start} max={end} onChange={e=>setStart(e.target.value)}/></label><label>To<input type="date" value={end} min={start} onChange={e=>setEnd(e.target.value)}/></label></div>}<button className="secondaryButton exportButton" disabled={!report||loading} onClick={exportExcel}>Export to Excel</button></div></section>
    {error&&<div className="formError">{error} <button onClick={()=>void load(start,end)}>Retry</button></div>}
    {loading&&!report?<div className="contentLoading">Loading reports…</div>:<>
      <div className="reportSummary">
        <article className="metricCard"><span>Sales</span><strong>{money(summary?.sales_total??0)}</strong><small>{summary?.sales_count??0} completed orders</small></article>
        <article className="metricCard"><span>Purchases</span><strong>{money(summary?.purchases_total??0)}</strong><small>{summary?.purchase_count??0} purchase orders</small></article>
        <article className="metricCard"><span>Sales less purchases</span><strong>{money((summary?.sales_total??0)-(summary?.purchases_total??0))}</strong><small>Before operating expenses</small></article>
        <article className="metricCard"><span>Average sale</span><strong>{money((summary?.sales_total??0)/Math.max(1,summary?.sales_count??0))}</strong><small>Per completed order</small></article>
      </div>
      <section className="reportChart adminCard"><div className="sectionActions"><div><h2>Sales and purchasing activity</h2><p>{new Date(start+"T00:00:00").toLocaleDateString()} – {new Date(end+"T00:00:00").toLocaleDateString()}</p></div><div className="chartLegend"><span className="salesKey">Sales</span><span className="purchaseKey">Purchases</span></div></div><div className="chartScroller"><div className="barChart">{(report?.daily??[]).map(row=><div className="barGroup" key={row.date} title={`${row.date}: ${money(row.sales)} sales, ${money(row.purchases)} purchases`}><div className="bars"><i className="salesBar" style={{height:`${Math.max(2,Number(row.sales)/max*100)}%`}}/><i className="purchaseBar" style={{height:`${Math.max(2,Number(row.purchases)/max*100)}%`}}/></div><small>{new Date(row.date+"T00:00:00").toLocaleDateString(undefined,{month:"short",day:"numeric"})}</small></div>)}</div></div></section>
      <div className="reportTables"><section><h2>Sales</h2><div className="tableWrap"><table><thead><tr><th>Receipt</th><th>Date</th><th>Customer</th><th>Total</th></tr></thead><tbody>{report?.sales.length?report.sales.map(row=><tr key={row.id}><td>{row.number}</td><td>{new Date(row.date).toLocaleString()}</td><td>{row.customer}</td><td>{money(row.total)}</td></tr>):<tr><td colSpan={4}>No sales in this period.</td></tr>}</tbody></table></div></section><section><h2>Purchases</h2><div className="tableWrap"><table><thead><tr><th>PO</th><th>Date</th><th>Supplier</th><th>Total</th></tr></thead><tbody>{report?.purchases.length?report.purchases.map(row=><tr key={row.id}><td>{row.number}</td><td>{new Date(row.date).toLocaleString()}</td><td>{row.supplier}</td><td>{money(row.total)}</td></tr>):<tr><td colSpan={4}>No purchases in this period.</td></tr>}</tbody></table></div></section></div>
    </>}
  </div>;
}
