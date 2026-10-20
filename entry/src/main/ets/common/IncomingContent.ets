import { url } from '@kit.ArkTS';

/** 外部入口只传递待处理内容，不携带发布指令。 */
export interface IncomingContent {
  kind: string;
  value: string;
}

/** 分享解析只依赖已声明接收的文字和链接字段。 */
export interface IncomingRecord {
  utd: string;
  content?: string;
}

/** 将已支持的外部链接转换为网页地址；未知协议和参数直接报错。 */
export function incomingLink(raw: string): IncomingContent {
  const parsed = url.URL.parseURL(raw.trim());
  if (parsed.username !== '' || parsed.password !== '' || parsed.port !== '') {
    throw new Error('unsupported_link_authority');
  }
  if (parsed.protocol === 'https:' &&
    /^(www\.)?(x|twitter)\.com$/i.test(parsed.hostname)) {
    return { kind: 'link', value: parsed.href };
  }
  if (parsed.protocol === 'twitter:' || parsed.protocol === 'crux:') {
    if (parsed.pathname !== '' && parsed.pathname !== '/') { throw new Error('unsupported_deep_link_path'); }
    if (parsed.hostname === 'status') {
      const id = parsed.params.get('id');
      if (id !== null && /^[0-9]+$/.test(id)) {
        return { kind: 'link', value: 'https://x.com/i/web/status/' + id };
      }
    } else if (parsed.hostname === 'user') {
      const handle = parsed.params.get('screen_name');
      if (handle !== null && /^[A-Za-z0-9_]{1,15}$/.test(handle)) {
        return { kind: 'link', value: 'https://x.com/' + handle };
      }
    }
  }
  throw new Error('unsupported_link');
}

/** 仅单独分享的站内链接用于跳转；混合文字保持原内容进入草稿。 */
export function incomingShare(records: IncomingRecord[]): IncomingContent {
  if (records.length === 0) { throw new Error('empty_share'); }
  const parts: string[] = [];
  for (const record of records) {
    if (record.utd !== 'general.hyperlink' && record.utd !== 'general.plain-text' &&
      record.utd !== 'general.text') { throw new Error('unsupported_share_type'); }
    if (record.content === undefined || record.content.trim() === '') { throw new Error('empty_share_content'); }
    parts.push(record.content);
  }
  const value = parts.join('\n');
  if (parts.length === 1 && /^https:\/\/(www\.)?(x|twitter)\.com([/?#]|$)\S*$/i.test(value.trim())) {
    return incomingLink(value);
  }
  return { kind: 'compose', value: value };
}
