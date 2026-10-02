import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "RetailFlow",
  description: "Multi-tenant retail sales and inventory management by PAOTechs",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
