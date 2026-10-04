"use client";

import { useEffect, useState } from "react";
import { BrandLogo } from "@/components/brand-logo";

type InstallPromptEvent = Event & {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
};

export function InstallAppPage() {
  const [installPrompt, setInstallPrompt] = useState<InstallPromptEvent | null>(null);
  const [isIos, setIsIos] = useState(false);
  const [installed, setInstalled] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    const standalone = window.matchMedia("(display-mode: standalone)").matches
      || ("standalone" in navigator && Boolean((navigator as Navigator & { standalone?: boolean }).standalone));
    setInstalled(standalone);
    setIsIos(/iphone|ipad|ipod/i.test(navigator.userAgent));

    function rememberPrompt(event: Event) {
      event.preventDefault();
      setInstallPrompt(event as InstallPromptEvent);
    }

    function confirmInstallation() {
      setInstalled(true);
      setInstallPrompt(null);
    }

    window.addEventListener("beforeinstallprompt", rememberPrompt);
    window.addEventListener("appinstalled", confirmInstallation);
    return () => {
      window.removeEventListener("beforeinstallprompt", rememberPrompt);
      window.removeEventListener("appinstalled", confirmInstallation);
    };
  }, []);

  async function install() {
    if (!installPrompt) {
      setMessage(isIos
        ? "In Safari, tap Share, then choose Add to Home Screen."
        : "Open this page in Chrome, then use the browser menu and choose Install app or Add to Home screen.");
      return;
    }
    await installPrompt.prompt();
    const choice = await installPrompt.userChoice;
    setMessage(choice.outcome === "accepted" ? "RetailFlow is being installed." : "Installation was cancelled. You can try again anytime.");
    setInstallPrompt(null);
  }

  return (
    <main className="installPage">
      <section className="installHero">
        <a href="/" aria-label="Return to RetailFlow"><BrandLogo className="installBrandLogo" /></a>
        <div className="installLayout">
          <div className="installCopy">
            <p className="eyebrow">RetailFlow mobile app</p>
            <h1>Run your store from your phone.</h1>
            <p className="summary">Install RetailFlow on Android or iPhone for quick access to orders, products, inventory, and daily store operations—without downloading from an app store.</p>
            {installed ? (
              <div className="installSuccess"><span>✓</span><div><strong>RetailFlow is installed</strong><p>Open it from your home screen or app launcher.</p></div></div>
            ) : (
              <button className="primaryButton installButton" onClick={() => void install()}>Install RetailFlow</button>
            )}
            {message && <p className="installMessage" role="status">{message}</p>}
            <a className="backToApp" href="/">Continue to RetailFlow in your browser →</a>
          </div>

          <div className="installPhone" aria-hidden="true">
            <div className="installPhoneTop" />
            <div className="installPhoneScreen">
              <img src="/brand/retailflow-icon-192.png?v=2" alt="" />
              <strong>RetailFlow</strong>
              <span>Sales and inventory,<br />built to flow.</span>
              <div className="installPhoneButton">Open app</div>
            </div>
          </div>
        </div>
      </section>

      <section className="installSteps" aria-label="Installation instructions">
        <article><span>Android</span><h2>Install from Chrome</h2><ol><li>Open this page in Chrome.</li><li>Tap <strong>Install RetailFlow</strong>.</li><li>Confirm <strong>Install</strong>.</li></ol></article>
        <article><span>iPhone or iPad</span><h2>Add from Safari</h2><ol><li>Open this page in Safari.</li><li>Tap the <strong>Share</strong> button.</li><li>Select <strong>Add to Home Screen</strong>.</li></ol></article>
      </section>
    </main>
  );
}
