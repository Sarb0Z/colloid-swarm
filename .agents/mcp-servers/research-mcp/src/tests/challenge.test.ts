import { describe, expect, it } from 'vitest';
import { detectChallenge } from '../core/challenge.js';
import { FetchError } from '../core/http-client.js';
import { classifyFailure } from '../mcp/tools/fetch-readable.tool.js';

describe('detectChallenge', () => {
  it('recognises a Cloudflare interstitial', () => {
    const body = '<html><head><title>Just a moment...</title></head><body>'
      + '<p>Checking your browser before accessing the site.</p></body></html>';
    expect(detectChallenge(body)).toBeTruthy();
  });

  it('recognises a human-verification wall', () => {
    expect(detectChallenge('<h1>Verify you are human</h1>')).toBeTruthy();
    expect(detectChallenge('Please complete the security check to continue')).toBeTruthy();
  });

  it('recognises the script-and-cookie demand', () => {
    expect(detectChallenge('Enable JavaScript and cookies to continue')).toBeTruthy();
  });

  it('names the signal that fired, so "blocked" is actionable', () => {
    expect(detectChallenge('Just a moment, please')).toBe('just a moment');
  });

  it('passes an ordinary page through', () => {
    const body = '<html><body><h1>Senior Backend Engineer</h1>'
      + '<p>We are hiring. Apply below.</p></body></html>';
    expect(detectChallenge(body)).toBeNull();
  });

  it('does not fire on an article that merely discusses bot protection', () => {
    // The phrase appears, but far past the head an interstitial would put it in.
    const body = `<html><body><article>${'Filler prose about web scraping. '.repeat(400)}`
      + 'Cloudflare will ask you to verify you are human.</article></body></html>';
    expect(detectChallenge(body)).toBeNull();
  });

  it('handles empty input', () => {
    expect(detectChallenge('')).toBeNull();
  });
});

describe('classifyFailure', () => {
  const http = (status: number) => new FetchError(`HTTP ${status}`, 'http', status);

  it('separates being refused from the page being gone', () => {
    // The distinction career-ops documents at length: conflating these recorded
    // a throttled board as expired and then skipped it indefinitely.
    expect(classifyFailure(http(403))).toBe('blocked');
    expect(classifyFailure(http(429))).toBe('blocked');
    expect(classifyFailure(http(503))).toBe('blocked');
    expect(classifyFailure(http(404))).toBe('not_found');
    expect(classifyFailure(http(410))).toBe('not_found');
  });

  it('keeps other server errors apart from a block', () => {
    expect(classifyFailure(http(500))).toBe('server_error');
    expect(classifyFailure(http(502))).toBe('server_error');
  });

  it('classifies remaining client errors', () => {
    expect(classifyFailure(http(400))).toBe('client_error');
    expect(classifyFailure(http(401))).toBe('client_error');
  });

  it('separates a timeout from another transport failure', () => {
    expect(classifyFailure(new FetchError('Timed out after 20000ms', 'network'))).toBe('timeout');
    expect(classifyFailure(new FetchError('socket hang up', 'network'))).toBe('network');
  });

  it('classifies a policy refusal and a size refusal', () => {
    expect(classifyFailure(new FetchError('non-public address', 'policy'))).toBe('policy');
    expect(classifyFailure(new FetchError('too large', 'size'))).toBe('size');
  });
});
