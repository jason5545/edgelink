export const isDeviceId = (value: unknown): value is string =>
  typeof value === "string" && /^[1-9][0-9]{8}$/.test(value);

export const isNonEmptyString = (value: unknown, maxLength = 256): value is string =>
  typeof value === "string" && value.trim().length > 0 && value.length <= maxLength;

export const now = () => Date.now();

export const parseJson = async <T>(request: Request): Promise<T | null> =>
  request.json().catch(() => null) as Promise<T | null>;
