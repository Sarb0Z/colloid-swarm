const secretKey =
  /(^|_)(?:access_token|api_key|apikey|auth|authorization|client_secret|code|cookie|credential|id_token|jwt|password|passwd|refresh_token|secret|session|sig|signature|token)($|_)/i;

export interface CredentialValues {
  bearerToken?: string;
  cookies?: Readonly<Record<string, string>>;
}

export class SecretRedactor {
  private constructor(private readonly variants: readonly string[]) {}

  static fromCredentials(credentials: CredentialValues | undefined): SecretRedactor {
    const values = [
      credentials?.bearerToken,
      ...Object.values(credentials?.cookies ?? {}),
    ].filter((value): value is string => typeof value === 'string' && value.length > 0);
    return new SecretRedactor(buildVariants(values));
  }

  static fromToolArguments(argumentsValue: unknown): SecretRedactor {
    if (!argumentsValue || typeof argumentsValue !== 'object') {
      return new SecretRedactor([]);
    }
    const credentials = (argumentsValue as { credentials?: unknown }).credentials;
    if (!credentials || typeof credentials !== 'object') return new SecretRedactor([]);
    const candidate = credentials as { bearerToken?: unknown; cookies?: unknown };
    const cookies: Record<string, string> = {};
    if (candidate.cookies && typeof candidate.cookies === 'object') {
      for (const [name, value] of Object.entries(candidate.cookies)) {
        if (typeof value === 'string') cookies[name] = value;
      }
    }
    return SecretRedactor.fromCredentials({
      bearerToken: typeof candidate.bearerToken === 'string' ? candidate.bearerToken : undefined,
      cookies,
    });
  }

  scrub(value: string): string {
    let scrubbed = value;
    for (const variant of this.variants) scrubbed = scrubbed.split(variant).join('[REDACTED]');
    for (const variant of this.variants) scrubbed = scrubPercentEquivalent(scrubbed, variant);
    return scrubbed;
  }

  scrubUrl(value: string): string {
    return this.scrub(sanitizeUrl(value));
  }

  scrubSerializable<T>(value: T): T {
    return scrubValue(value, this) as T;
  }
}

export function sanitizeUrl(raw: string): string {
  try {
    const url = new URL(raw);
    for (const key of [...url.searchParams.keys()]) {
      if (secretKey.test(key.replace(/[.-]/g, '_'))) url.searchParams.set(key, '[REDACTED]');
    }
    return url.toString();
  } catch {
    return '[invalid URL]';
  }
}

export function sanitizeSetCookies(values: readonly string[]): string[] {
  return values.map((value) => {
    const separator = value.indexOf(';');
    const first = separator === -1 ? value : value.slice(0, separator);
    const attributes = separator === -1 ? '' : value.slice(separator);
    const equals = first.indexOf('=');
    const name = equals > 0 ? first.slice(0, equals).trim() : 'cookie';
    return `${name}=[REDACTED]${attributes}`;
  });
}

function buildVariants(values: readonly string[]): string[] {
  const variants = new Set<string>();
  for (const value of values) {
    addVariant(variants, value);
    addVariant(variants, encodeURIComponent(value));
    addVariant(variants, encodeURIComponent(encodeURIComponent(value)));
    addVariant(variants, new URLSearchParams({ value }).toString().slice('value='.length));
    try {
      addVariant(variants, decodeURIComponent(value.replace(/\+/g, ' ')));
    } catch {
      // The supplied value is not URL-encoded.
    }
  }
  return [...variants].sort((left, right) => right.length - left.length || left.localeCompare(right));
}

function addVariant(variants: Set<string>, value: string): void {
  if (!value) return;
  variants.add(value);
}

function scrubPercentEquivalent(value: string, variant: string): string {
  if (!/%[0-9A-Fa-f]{2}/.test(variant)) return value;
  const normalizedValue = normalizePercentTriplets(value);
  const normalizedVariant = normalizePercentTriplets(variant);
  const pieces: string[] = [];
  let cursor = 0;
  let match = normalizedValue.indexOf(normalizedVariant, cursor);
  if (match === -1) return value;
  while (match !== -1) {
    pieces.push(value.slice(cursor, match), '[REDACTED]');
    cursor = match + variant.length;
    match = normalizedValue.indexOf(normalizedVariant, cursor);
  }
  pieces.push(value.slice(cursor));
  return pieces.join('');
}

function normalizePercentTriplets(value: string): string {
  return value.replace(/%[0-9A-Fa-f]{2}/g, (triplet) => triplet.toUpperCase());
}

function scrubValue(value: unknown, redactor: SecretRedactor): unknown {
  if (typeof value === 'string') return redactor.scrub(value);
  if (Array.isArray(value)) return value.map((entry) => scrubValue(entry, redactor));
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, scrubValue(entry, redactor)]),
    );
  }
  return value;
}
