// Answers collected across pages. Every one is also sent to Superwall as a user attribute,
// with the stable kebab-case values below (audiences are built on them; never rename one).

export type Feeling = "calm" | "a-little-uneasy" | "nervous" | "very-anxious";
export type Help = "when" | "how-long" | "normal" | "calm-down" | "delays";
export type Frequency = "yearly-or-less" | "few-a-year" | "monthly-plus";
export type Source = "app-store" | "social" | "friend" | "other";

export const answers: {
  feeling?: Feeling;
  help: Help[];
  frequency?: Frequency;
  source?: Source;
} = { help: [] };
