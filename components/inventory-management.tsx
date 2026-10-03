"use client";

import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";
import { supabase } from "@/lib/supabase/client";

type Branch = { id: string; name: string; code: string; active: boolean };
type InventoryData = {
  categories: Array<{ id: string; name: string }>;
  products: Array<{ id:string;name:string;sku:string;barcode:string|null;description:string|null;image_path:string|null;image_url:string|null;unit:string;active:boolean;category_id:string|null;category_name:string|null;branches:Array<{branch_id:string;branch_name:string;selling_price:number;quantity:number;low_stock_threshold:number;active:boolean}> }>;
  movements: Array<{id:string;product_name:string;sku:string;branch_name:string;movement_type:string;quantity_delta:number;quantity_after:number;reason:string|null;created_at:string}>;
};

export function InventoryManagement({ organizationId, branches }: { organizationId:string; branches:Branch[] }) {
  const [data,setData]=useState<InventoryData|null>(null); const [branchId,setBranchId]=useState(branches[0]?.id??"");
  const [view,setView]=useState<"products"|"movements">("products"); const [panel,setPanel]=useState<""|"product"|"category"|"adjust">("");
  const [selectedProduct,setSelectedProduct]=useState(""); const [loading,setLoading]=useState(true); const [busy,setBusy]=useState(false); const [error,setError]=useState(""); const [message,setMessage]=useState("");
  const load=useCallback(async()=>{setLoading(true);setError("");const{data:result,error:rpcError}=await supabase.rpc("get_inventory_workspace",{p_organization_id:organizationId});if(rpcError)setError(rpcError.message);else{const next=result as InventoryData;next.products=next.products.map(product=>({...product,image_url:product.image_path?supabase.storage.from("product-images").getPublicUrl(product.image_path).data.publicUrl:null}));setData(next);}setLoading(false);},[organizationId]);
  useEffect(()=>{void load();},[load]);
  const rows=useMemo(()=>data?.products.map(product=>({product,stock:product.branches.find(b=>b.branch_id===branchId)}))??[],[data,branchId]);
  async function category(event:FormEvent<HTMLFormElement>){event.preventDefault();setBusy(true);setError("");const f=new FormData(event.currentTarget);const{error:e}=await supabase.rpc("create_product_category",{p_organization_id:organizationId,p_name:String(f.get("name"))});if(e)setError(e.message);else{setMessage("Category created.");setPanel("");await load();}setBusy(false);}
  async function product(event:FormEvent<HTMLFormElement>){
    event.preventDefault();setBusy(true);setError("");setMessage("");const f=new FormData(event.currentTarget);
    const{data:productId,error:e}=await supabase.rpc("create_inventory_product",{p_organization_id:organizationId,p_category_id:String(f.get("category"))||null,p_name:String(f.get("name")),p_sku:String(f.get("sku")),p_barcode:String(f.get("barcode")),p_description:String(f.get("description")),p_unit:String(f.get("unit")),p_branch_id:String(f.get("branch")),p_selling_price:Number(f.get("price")),p_opening_quantity:Number(f.get("quantity")),p_low_stock_threshold:Number(f.get("threshold"))});
    if(e){setError(e.message);setBusy(false);return;}
    const image=f.get("image");
    if(image instanceof File&&image.size>0){
      try{
        const compressed=await compressProductImage(image);
        const extension=compressed.type==="image/png"?"png":"jpg";
        const path=`${organizationId}/${String(productId)}/${crypto.randomUUID()}.${extension}`;
        const{error:uploadError}=await supabase.storage.from("product-images").upload(path,compressed,{contentType:compressed.type,upsert:false});
        if(uploadError)throw uploadError;
        const{error:imageError}=await supabase.rpc("set_product_image",{p_product_id:productId,p_image_path:path});
        if(imageError)throw imageError;
        setMessage("Product and image created successfully.");
      }catch(imageError){setMessage("Product created, but its image could not be uploaded.");setError(imageError instanceof Error?imageError.message:"Image upload failed");}
    }else setMessage("Product created with opening branch inventory.");
    setPanel("");await load();setBusy(false);
  }
  async function adjust(event:FormEvent<HTMLFormElement>){event.preventDefault();setBusy(true);setError("");const f=new FormData(event.currentTarget);const{error:e}=await supabase.rpc("adjust_inventory_stock",{p_organization_id:organizationId,p_branch_id:branchId,p_product_id:selectedProduct,p_quantity_delta:Number(f.get("delta")),p_reason:String(f.get("reason"))});if(e)setError(e.message);else{setMessage("Stock adjusted and movement recorded.");setPanel("");await load();}setBusy(false);}
  if(loading)return <div className="contentLoading">Loading products and inventory…</div>;
  return <div className="contentStack inventoryWorkspace">{error&&<div className="formError">{error}</div>}{message&&<div className="formSuccess">{message}</div>}<div className="inventoryToolbar"><div className="modeTabs inventoryTabs"><button className={view==="products"?"active":""} onClick={()=>setView("products")}>Products</button><button className={view==="movements"?"active":""} onClick={()=>setView("movements")}>Movement history</button></div><label>Branch<select value={branchId} onChange={e=>setBranchId(e.target.value)}>{branches.filter(b=>b.active).map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></label><div className="rowActions"><button className="secondaryButton" onClick={()=>setPanel(panel==="category"?"":"category")}>Add category</button><button className="primaryButton compact" onClick={()=>setPanel(panel==="product"?"":"product")}>Add product</button></div></div>
  {panel==="category"&&<form className="inlineForm categoryForm" onSubmit={category}><label>Category name<input name="name" required/></label><button className="primaryButton" disabled={busy}>Create category</button></form>}
  {panel==="product"&&<form className="inventoryForm" onSubmit={product}><div className="formGrid"><label>Product name<input name="name" required/></label><label>SKU<input name="sku" required pattern="[A-Za-z0-9-]+"/></label><label>Barcode<input name="barcode" inputMode="numeric"/></label><label>Category<select name="category"><option value="">Uncategorized</option>{data?.categories.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label><label>Unit<input name="unit" defaultValue="piece" required/></label><label>Initial branch<select name="branch" defaultValue={branchId}>{branches.filter(b=>b.active).map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></label><label>Selling price<input name="price" type="number" min="0" step="0.01" required/></label><label>Opening quantity<input name="quantity" type="number" min="0" step="0.001" defaultValue="0" required/></label><label>Low-stock threshold<input name="threshold" type="number" min="0" step="0.001" defaultValue="0" required/></label><label className="fullWidth">Product image<input name="image" type="file" accept="image/jpeg,image/png,image/webp" capture="environment"/><small>Upload an image or use your device camera. Images are resized before upload.</small></label><label className="fullWidth">Description<input name="description"/></label></div><button className="primaryButton compact" disabled={busy}>{busy?"Creating…":"Create product"}</button></form>}
  {panel==="adjust"&&<form className="inlineForm adjustmentForm" onSubmit={adjust}><label>Quantity change<input name="delta" type="number" step="0.001" required placeholder="Use -2 to reduce stock"/></label><label>Reason<input name="reason" required placeholder="Correction, damaged stock…"/></label><button className="primaryButton" disabled={busy}>{busy?"Saving…":"Record adjustment"}</button></form>}
  {view==="products"?<div className="tableWrap"><table><thead><tr><th>Product</th><th>Category</th><th>Price</th><th>On hand</th><th>Status</th><th>Action</th></tr></thead><tbody>{rows.map(({product,stock})=><tr key={product.id}><td><div className="productIdentity">{product.image_url?<img src={product.image_url} alt=""/>:<span className="productImagePlaceholder">▦</span>}<div><strong>{product.name}</strong><small>{product.sku}{product.barcode?` · ${product.barcode}`:""}</small></div></div></td><td>{product.category_name??"Uncategorized"}</td><td>{stock?`₱${Number(stock.selling_price).toFixed(2)}`:"Not configured"}</td><td>{stock?`${stock.quantity} ${product.unit}`:"—"}</td><td>{stock&&Number(stock.quantity)<=Number(stock.low_stock_threshold)?<span className="statusPill warning">Low stock</span>:<span className="statusPill">Available</span>}</td><td><button className="tableAction" disabled={!stock} onClick={()=>{setSelectedProduct(product.id);setPanel("adjust");}}>Adjust</button></td></tr>)}</tbody></table></div>:<div className="tableWrap"><table><thead><tr><th>Date</th><th>Product</th><th>Branch</th><th>Movement</th><th>Change</th><th>Balance</th><th>Reason</th></tr></thead><tbody>{(data?.movements??[]).map(m=><tr key={m.id}><td>{new Date(m.created_at).toLocaleString()}</td><td><strong>{m.product_name}</strong><small>{m.sku}</small></td><td>{m.branch_name}</td><td className="capitalize">{m.movement_type.replace("_"," ")}</td><td className={Number(m.quantity_delta)>0?"positive":"negative"}>{Number(m.quantity_delta)>0?"+":""}{m.quantity_delta}</td><td>{m.quantity_after}</td><td>{m.reason??"—"}</td></tr>)}</tbody></table></div>}
  </div>;
}

async function compressProductImage(file:File):Promise<Blob>{
  const bitmap=await createImageBitmap(file);
  const max=1200;const scale=Math.min(1,max/Math.max(bitmap.width,bitmap.height));
  const canvas=document.createElement("canvas");canvas.width=Math.round(bitmap.width*scale);canvas.height=Math.round(bitmap.height*scale);
  const context=canvas.getContext("2d");if(!context)throw new Error("This browser cannot process images.");
  context.drawImage(bitmap,0,0,canvas.width,canvas.height);bitmap.close();
  return await new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error("Image compression failed.")),"image/jpeg",.82));
}
