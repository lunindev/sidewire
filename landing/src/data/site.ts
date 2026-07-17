/**
 * Single source of truth for all landing-page copy, typed.
 *
 * Product truth (do not drift from this): Sidewire is NOT screen sharing. Your main Mac gains a
 * real second screen; that screen physically lives on a spare Mac. Every line below follows from
 * that framing.
 */

// ─── Owner-set links ────────────────────────────────────────────────────────────────────────
// Set to the repo's actual owner (github.com/lunindev/sidewire). `download` points at the latest
// release page; once you publish signed assets, GitHub serves them there.
export const links = {
  github: 'https://github.com/lunindev/sidewire',
  download: 'https://github.com/lunindev/sidewire/releases/latest',
  docs: 'https://github.com/lunindev/sidewire/tree/main/app/docs',
} as const;

export const site = {
  name: 'Sidewire',
  tagline: 'Your spare Mac is a second display.',
  description:
    'Give your main Mac a second screen using a Mac you already own — a real extra desktop over Thunderbolt or Wi‑Fi. Not screen sharing.',
  url: 'https://sidewire.app',
} as const;

// ─── Navigation ─────────────────────────────────────────────────────────────────────────────
export interface NavLink {
  readonly label: string;
  readonly href: string;
}

export const nav: readonly NavLink[] = [
  { label: 'Features', href: '#features' },
  { label: 'How it works', href: '#how' },
  { label: 'Specs', href: '#specs' },
  { label: 'FAQ', href: '#faq' },
];

// ─── Feature grid ───────────────────────────────────────────────────────────────────────────
export interface Feature {
  readonly title: string;
  readonly body: string;
  /** Key into the <IconSet> switch — keeps SVGs out of the data file. */
  readonly icon:
    | 'display'
    | 'bolt'
    | 'cursor'
    | 'gauge'
    | 'lock'
    | 'shield'
    | 'devices'
    | 'refresh';
  /** Feature cards that should span two columns on wide layouts. */
  readonly wide?: boolean;
}

export const features: readonly Feature[] = [
  {
    icon: 'display',
    title: 'A real second desktop',
    body: 'Sidewire creates a genuine virtual display on your main Mac and streams it to the spare one. Menu bar, Dock, window snapping — it behaves exactly like a monitor you plugged in, because to macOS it is one.',
    wide: true,
  },
  {
    icon: 'bolt',
    title: 'One‑click Thunderbolt',
    body: 'Join the two Macs with a cable and a green ⚡ button appears — one click, no typing, no network. Wi‑Fi works too when you’d rather stay wireless.',
  },
  {
    icon: 'cursor',
    title: 'Keyboard & mouse, everywhere',
    body: 'Slide the pointer onto the extra screen and keep typing. Input is forwarded instantly, and the local cursor never round‑trips through the video — it just moves.',
  },
  {
    icon: 'gauge',
    title: 'Hardware‑fast, adaptive',
    body: 'Frames are encoded by the Mac’s media engine (HEVC or H.264 via VideoToolbox) and the bitrate tracks your link quality in real time, so it stays smooth on a cable or across the room.',
  },
  {
    icon: 'lock',
    title: 'Pair once, securely',
    body: 'A 6‑digit PIN over TLS 1.3 with a CPace PAKE. Pair the two Macs once and the trust is remembered — no accounts, no cloud in the loop.',
  },
  {
    icon: 'shield',
    title: 'Private by design',
    body: 'No accounts. No analytics. No telemetry. The stream is direct between your two machines. The app’s only network call is an update check — and only when you ask.',
  },
  {
    icon: 'devices',
    title: 'A PC can play too',
    body: 'A spare Windows or Linux machine can be the extra screen via the native client — it speaks the identical wire protocol. (The main machine, the one gaining a screen, is always a Mac.)',
  },
  {
    icon: 'refresh',
    title: 'Stays up on its own',
    body: 'Self‑healing reconnect with backoff, sleep/wake recovery, and encoder‑stall watchdogs keep the second screen alive — no babysitting when a laptop lid closes or Wi‑Fi hiccups.',
  },
];

// ─── How it works ───────────────────────────────────────────────────────────────────────────
export interface Step {
  readonly n: string;
  readonly title: string;
  readonly body: string;
}

export const steps: readonly Step[] = [
  {
    n: '01',
    title: 'Launch it on both Macs',
    body: 'Sidewire is one universal app — the same build runs on Apple silicon and Intel. A first‑run welcome explains the two roles.',
  },
  {
    n: '02',
    title: 'Pick the roles',
    body: 'Choose “Main Mac” on your primary machine and “Extra screen” on the spare. The spare shows a 6‑digit pairing PIN.',
  },
  {
    n: '03',
    title: 'Connect & drag a window across',
    body: 'Enter the PIN, then click the ⚡ Thunderbolt button or pick the Mac over Wi‑Fi. A new desktop appears — drag any window onto it. Press Esc on the spare to leave fullscreen.',
  },
];

// ─── Spec / trust band ──────────────────────────────────────────────────────────────────────
export interface Spec {
  readonly label: string;
  readonly value: string;
}

export const specs: readonly Spec[] = [
  { label: 'Display', value: 'CGVirtualDisplay + ScreenCaptureKit' },
  { label: 'Encoding', value: 'HEVC / H.264 · VideoToolbox (hardware)' },
  { label: 'Transport', value: 'TCP · TLS 1.3 · CPace PAKE pairing' },
  { label: 'Link', value: 'Thunderbolt direct or LAN · adaptive bitrate' },
  { label: 'Platform', value: 'Universal 2 (Apple silicon + Intel) · macOS 14+' },
  { label: 'Extra‑screen client', value: 'macOS, or native Windows / Linux (Rust)' },
  { label: 'Updates', value: 'Sparkle 2 · EdDSA‑signed appcast' },
  { label: 'Privacy', value: '100% local · no accounts · no telemetry' },
];

// ─── FAQ ────────────────────────────────────────────────────────────────────────────────────
export interface Faq {
  readonly q: string;
  readonly a: string;
}

export const faqs: readonly Faq[] = [
  {
    q: 'Is this screen sharing or remote desktop?',
    a: 'No. Remote desktop mirrors a screen you already have. Sidewire adds a new one — a second desktop that lives on the spare Mac, that your main Mac treats as an extra monitor you can drag windows onto.',
  },
  {
    q: 'Do I need a Thunderbolt cable?',
    a: 'No — Wi‑Fi works fine. A direct cable just gives you the lowest latency and a one‑click connect, so it’s the nicer option when both Macs are on the same desk.',
  },
  {
    q: 'Does the spare Mac need to be powerful?',
    a: 'Not at all. It only decodes video and shows a window, so an old Mac on macOS 14+ is perfect. The heavy lifting (creating the display and encoding it) happens on your main Mac.',
  },
  {
    q: 'Can I use a Windows or Linux PC as the extra screen?',
    a: 'Yes, with the native client — it pairs with a Mac and speaks the exact same protocol. The one rule: the machine that gains the screen (the “Main Mac”) has to be a Mac, because creating a virtual display is macOS‑specific.',
  },
  {
    q: 'Is my screen data sent anywhere?',
    a: 'Never. The stream is direct between your two machines and encrypted end‑to‑end with TLS 1.3. There are no servers, no accounts, and no analytics anywhere in the app.',
  },
  {
    q: 'How do updates work?',
    a: 'Sidewire checks a signed appcast with Sparkle when you ask, or in the background if you opt in. That signed update check is the app’s first and only phone‑home — everything else is 100% local.',
  },
];
