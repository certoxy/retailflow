import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "RetailFlow",
  description: "Multi-branch retail inventory and operations management by PAOTechs",
  manifest: "/manifest.webmanifest",
  icons: {
    icon: "/favicon.png?v=2",
    apple: "/brand/retailflow-icon-192.png?v=2",
  },
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
