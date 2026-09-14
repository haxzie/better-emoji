// Types shared by the browser picker and the Worker API.

export interface EmojiEntry {
  /** The emoji character itself */
  c: string;
  /** CLDR name, e.g. "grinning face" */
  n: string;
  /** CLDR keywords */
  t: string[];
  /** emojibase group id */
  g: number;
  /** Skin-tone variants, if any */
  s?: string[];
}

/** [emoji index, score] */
export type Hit = [number, number];
