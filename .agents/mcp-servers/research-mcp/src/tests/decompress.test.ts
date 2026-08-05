import { brotliCompressSync, deflateSync, gzipSync } from 'node:zlib';
import { describe, expect, it } from 'vitest';
import { decompress, FetchError } from '../core/http-client.js';

const CAP = 1 << 20; // 1 MiB

describe('decompress', () => {
  it.each([
    ['gzip', gzipSync],
    ['deflate', deflateSync],
    ['br', brotliCompressSync],
  ] as const)('round-trips %s within the cap', async (encoding, compress) => {
    const payload = Buffer.from('hello '.repeat(100));
    expect((await decompress(compress(payload), encoding, CAP)).toString()).toBe(payload.toString());
  });

  it.each([
    ['gzip', gzipSync],
    ['deflate', deflateSync],
    ['br', brotliCompressSync],
  ] as const)('rejects a %s bomb that inflates past the cap', async (encoding, compress) => {
    // Highly compressible: the transport's byte cap counts compressed bytes and
    // would wave this through, so the ceiling has to live at decompression.
    const bomb = compress(Buffer.alloc(64 * 1024 * 1024));
    expect(bomb.length).toBeLessThan(CAP);
    await expect(decompress(bomb, encoding, CAP)).rejects.toThrow(FetchError);
    await expect(decompress(bomb, encoding, CAP)).rejects.toThrow(/exceeds 1048576 bytes/);
  });

  it('classifies a bomb as a size failure, not a network failure', async () => {
    const bomb = gzipSync(Buffer.alloc(64 * 1024 * 1024));
    await expect(decompress(bomb, 'gzip', CAP)).rejects.toMatchObject({ kind: 'size' });
  });

  it('passes identity and empty encodings through untouched', async () => {
    const raw = Buffer.from('plain');
    expect(await decompress(raw, '', CAP)).toBe(raw);
    expect(await decompress(raw, 'identity', CAP)).toBe(raw);
    expect(await decompress(raw, '  IDENTITY  ', CAP)).toBe(raw);
  });

  it('reports corrupt compressed data as a network failure', async () => {
    await expect(decompress(Buffer.from('not gzip at all'), 'gzip', CAP)).rejects.toMatchObject({
      kind: 'network',
    });
  });

  it('returns raw bytes for an encoding it does not implement', async () => {
    const raw = Buffer.from('zstd-ish');
    expect(await decompress(raw, 'zstd', CAP)).toBe(raw);
  });
});
