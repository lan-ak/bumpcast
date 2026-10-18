import type { PropsWithChildren, ReactNode } from "react";
import { useHaptics } from "superwall/hooks";

/** A single answer row. Single-select rows advance on tap; multi-select rows toggle. */
export function Option({
  selected,
  multi,
  onPress,
  children,
}: PropsWithChildren<{ selected: boolean; multi?: boolean; onPress: () => void }>) {
  const haptics = useHaptics();
  return (
    <button
      type="button"
      className={`option${selected ? " option--on" : ""}`}
      role={multi ? "checkbox" : "radio"}
      aria-checked={selected}
      onClick={() => {
        haptics.selection();
        onPress();
      }}
    >
      {multi && <span className={`check${selected ? " check--on" : ""}`} aria-hidden="true" />}
      {children}
    </button>
  );
}

export function PrimaryButton({ onPress, children, dimmed }: { onPress: () => void; children: ReactNode; dimmed?: boolean }) {
  const haptics = useHaptics();
  return (
    <button
      type="button"
      className={`cta${dimmed ? " cta--dimmed" : ""}`}
      onClick={() => {
        haptics.light();
        onPress();
      }}
    >
      {children}
    </button>
  );
}

/** Page frame: content on top, the primary action pinned at the bottom. */
export function Page({ children, footer, className }: { children: ReactNode; footer?: ReactNode; className?: string }) {
  return (
    <main className={`page${className ? ` ${className}` : ""}`}>
      <div className="page-body">{children}</div>
      {footer && <div className="page-footer">{footer}</div>}
    </main>
  );
}
