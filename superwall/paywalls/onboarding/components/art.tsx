// BumpCast artwork drawn in SVG: the app icon ("Calm line", DESIGN_SPEC §8) and the
// water-glass severity gauge (§2). The glass is a gauge only, never a brand mark.

const SEVERITY = {
  smooth: { color: "#3A9A8F", ripple: 0 },
  light: { color: "#C99A2E", ripple: 0.35 },
} as const;

export function Glass({ severity, size }: { severity: keyof typeof SEVERITY; size: number }) {
  const { color, ripple } = SEVERITY[severity];
  const w = size * 0.8;
  const h = size;
  const inset = w * 0.12;
  const level = h * 0.45;
  const amplitude = h * 0.08 * ripple;
  const left = inset * 0.45;
  const right = w - inset * 0.45;
  let water = `M${inset},${h} L${left},${level}`;
  for (let i = 0; i <= 24; i++) {
    const t = i / 24;
    water += ` L${(left + (right - left) * t).toFixed(1)},${(level + amplitude * Math.sin(t * 2.2 * 2 * Math.PI)).toFixed(1)}`;
  }
  water += ` L${w - inset},${h} Z`;
  return (
    <svg width={w} height={h} viewBox={`-2 -2 ${w + 4} ${h + 4}`} aria-hidden="true" style={{ flex: "none" }}>
      <path d={water} fill={color} fillOpacity={0.85} />
      <path
        d={`M0,0 L${inset},${h} L${w - inset},${h} L${w},0`}
        fill="none"
        stroke={color}
        strokeWidth={Math.max(1.4, size / 16)}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

/** The app icon at small sizes (notification previews, the paywall header). */
export function AppIcon({ size }: { size: number }) {
  const id = `icon-${size}`;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 1024 1024"
      aria-hidden="true"
      style={{ borderRadius: size * 0.225, flex: "none" }}
    >
      <defs>
        <linearGradient id={`${id}-sky`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#F6D9C4" />
          <stop offset="1" stopColor="#DFE6EF" />
        </linearGradient>
        <linearGradient id={`${id}-water`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#A9C6E2" />
          <stop offset="1" stopColor="#7FA6CC" />
        </linearGradient>
      </defs>
      <rect width="1024" height="604" fill={`url(#${id}-sky)`} />
      <circle cx="655" cy="604" r="154" fill="#FFF3E8" fillOpacity={0.95} />
      <rect y="604" width="1024" height="420" fill={`url(#${id}-water)`} />
      <path
        d="M133 604 C215 604 246 502 317 502 S420 604 502 604 L1085 604"
        fill="none"
        stroke="#1F5F6E"
        strokeWidth={size <= 40 ? 72 : 51}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
