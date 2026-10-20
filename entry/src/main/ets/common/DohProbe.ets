import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0A11;
const TAG: string = 'OpenTwit';
const PROBE_HOST: string = 'x.com';
const PROBE_TIMEOUT_MS: number = 4000;
const MAX_RESPONSE_BYTES: number = 64 * 1024;

export type ProbeStatus = 'ok' | 'unreachable' | 'bad_response' | 'rcode';

export interface ProbeResult {
  status: ProbeStatus;
  latencyMs: number;
  rcode: number;
}

/** RFC 1035 A query: the probe measures this DoH node, it is not an ECH probe. */
export function buildAddressQuery(host: string): Uint8Array {
  const labels = host.split('.');
  let total = 12 + 1 + 4;
  for (let i = 0; i < labels.length; i++) {
    const length = labels[i].length;
    if (length === 0 || length > 63) {
      return new Uint8Array(0);
    }
    total += 1 + length;
  }
  if (total > 255 + 12 + 4) {
    return new Uint8Array(0);
  }
  const query = new Uint8Array(total);
  // ID 0, flags RD=1, QDCOUNT=1, ANCOUNT/NSCOUNT/ARCOUNT=0.
  query[2] = 1;
  query[5] = 1;
  let offset = 12;
  for (let i = 0; i < labels.length; i++) {
    const label = labels[i];
    query[offset] = label.length;
    offset++;
    for (let j = 0; j < label.length; j++) {
      query[offset] = label.charCodeAt(j);
      offset++;
    }
  }
  query[offset] = 0;
  offset++;
  // QTYPE A (1), QCLASS IN (1).
  query[offset] = 0;
  query[offset + 1] = 1;
  query[offset + 2] = 0;
  query[offset + 3] = 1;
  return query;
}

export function readRcode(response: ArrayBuffer): number {
  if (response.byteLength < 12) {
    return -1;
  }
  return new Uint8Array(response)[3] & 0x0F;
}

export class DohProbe {
  private requests: http.HttpRequest[] = [];

  async probe(nodeUrl: string): Promise<ProbeResult> {
    const query = buildAddressQuery(PROBE_HOST);
    if (query.length === 0) {
      return { status: 'bad_response', latencyMs: -1, rcode: -1 };
    }
    const encoder = new util.Base64Helper();
    let encoded = encoder.encodeToStringSync(query, util.Type.BASIC_URL_SAFE);
    while (encoded.endsWith('=')) {
      encoded = encoded.substring(0, encoded.length - 1);
    }
    const separator = nodeUrl.indexOf('?') >= 0 ? '&' : '?';
    const probeUrl = nodeUrl + separator + 'dns=' + encoded;
    const request = http.createHttp();
    this.requests.push(request);
    const started = Date.now();
    try {
      const response = await request.request(probeUrl, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: PROBE_TIMEOUT_MS,
        readTimeout: PROBE_TIMEOUT_MS,
        maxLimit: MAX_RESPONSE_BYTES,
        usingCache: false,
        header: { 'Accept': 'application/dns-message' }
      });
      const elapsed = Math.max(1, Date.now() - started);
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        hilog.warn(DOMAIN, TAG, 'event=doh_probe status=bad_response http=%{public}d', response.responseCode);
        return { status: 'bad_response', latencyMs: elapsed, rcode: -1 };
      }
      const rcode = readRcode(response.result as ArrayBuffer);
      if (rcode < 0) {
        hilog.warn(DOMAIN, TAG, 'event=doh_probe status=bad_response bytes=%{public}d',
          (response.result as ArrayBuffer).byteLength);
        return { status: 'bad_response', latencyMs: elapsed, rcode: -1 };
      }
      hilog.info(DOMAIN, TAG, 'event=doh_probe status=%{public}s ms=%{public}d rcode=%{public}d',
        rcode === 0 ? 'ok' : 'rcode', elapsed, rcode);
      return { status: rcode === 0 ? 'ok' : 'rcode', latencyMs: elapsed, rcode: rcode };
    } catch (err) {
      const error = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'event=doh_probe_failed code=%{public}d', error.code);
      return { status: 'unreachable', latencyMs: -1, rcode: -1 };
    } finally {
      const index = this.requests.indexOf(request);
      if (index >= 0) {
        this.requests.splice(index, 1);
        request.destroy();
      }
    }
  }

  cancel(): void {
    const pending = this.requests.slice();
    this.requests = [];
    for (let i = 0; i < pending.length; i++) {
      pending[i].destroy();
    }
  }
}
