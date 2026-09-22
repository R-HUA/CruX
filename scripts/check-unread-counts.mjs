#!/usr/bin/env node
// Checks the unread-count script the shell injects into x.com.
//
// UNREAD_COUNTS_SCRIPT in entry/src/main/ets/common/WebChrome.ets is a string
// of JavaScript, so nothing type-checks it: this extracts it the same way the
// ArkTS build will, then runs it against a stub DOM covering the shapes the
// page can hand back. No device, no network.
//
//   node scripts/check-unread-counts.mjs

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const chrome = join(here, '..', 'entry', 'src', 'main', 'ets', 'common', 'WebChrome.ets');

function extractScript() {
  const source = readFileSync(chrome, 'utf8');
  const marker = 'export const UNREAD_COUNTS_SCRIPT: string =';
  const start = source.indexOf(marker);
  if (start < 0) {
    throw new Error(`UNREAD_COUNTS_SCRIPT not found in ${chrome}`);
  }
  const declaration = source.slice(source.indexOf('=', start) + 1);
  const end = declaration.indexOf("';\n");
  if (end < 0) {
    throw new Error('could not find the end of the UNREAD_COUNTS_SCRIPT literal');
  }
  const literal = declaration.slice(0, end + 1);
  // ArkTS string concatenation is JavaScript string concatenation, so this is
  // exactly the source the WebView receives.
  return eval(literal);
}

function element(options = {}) {
  return {
    getAttribute(name) {
      return options.attrs?.[name] ?? null;
    },
    textContent: options.text ?? '',
    querySelectorAll() {
      return options.kids ?? [];
    }
  };
}

function run(script, bySelector, title) {
  const document = {
    title,
    querySelectorAll(selector) {
      return bySelector[selector] ?? [];
    }
  };
  return new Function('document', `return ${script}`)(document);
}

const NOTIFICATIONS = 'a[href="/notifications"],[data-testid="AppTabBar_Notifications_Link"]';
const MESSAGES = 'a[href="/messages"],a[href="/i/chat"],'
  + '[data-testid="AppTabBar_DirectMessage_Link"],[data-testid="AppTabBar_Messages_Link"]';

// "-1" is the load-bearing part of the contract: it means the page has not
// published that entry yet, and the shell must keep the count it already has
// rather than clearing the badge (which is what made badges drop out while
// moving between tabs).
const cases = [
  ['English accessible labels', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'Notifications (3 unread notifications)' }, text: 'Notifications' })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Direct Messages (2 unread conversations)' }, text: 'Messages' })]
  }, '', '3/2'],
  ['Arabic-Indic digits', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'الإشعارات (٣ إشعارات غير مقروءة)' } })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'الرسائل المباشرة (١٢ محادثة غير مقروءة)' } })]
  }, '', '3/12'],
  ['counter drawn as its own badge node', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'Notifications' }, kids: [element({ text: '\n  4\n' })] })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' } })]
  }, '', '4/0'],
  ['entries present but nothing unread', {
    [NOTIFICATIONS]: [element({ attrs: { 'aria-label': 'Notifications' }, text: 'Notifications' })],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' }, text: 'Messages' })]
  }, '', '0/0'],
  ['title prefix fills in for a missing notification entry', {
    [NOTIFICATIONS]: [], [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' } })]
  }, '(7) Home / X', '7/0'],
  ['mid-load: nothing published yet', { [NOTIFICATIONS]: [], [MESSAGES]: [] }, '', '-1/-1'],
  ['mid-load on a page with a stale title', { [NOTIFICATIONS]: [], [MESSAGES]: [] }, 'Home / X', '-1/-1'],
  ['signed out', { [NOTIFICATIONS]: [], [MESSAGES]: [] }, 'X. It’s what’s happening / X', '-1/-1'],
  ['labelled entry wins over an unlabelled one', {
    [NOTIFICATIONS]: [
      element({ attrs: { 'aria-label': 'Home (New unread posts)' }, text: 'Home' }),
      element({ attrs: { 'aria-label': 'Notifications (9 unread notifications)' }, text: 'Notifications' })
    ],
    [MESSAGES]: [element({ attrs: { 'aria-label': 'Messages' } })]
  }, '', '9/0']
];

const script = extractScript();
let failed = 0;
for (const [name, bySelector, title, expected] of cases) {
  let actual;
  try {
    actual = run(script, bySelector, title);
  } catch (err) {
    actual = `threw ${err.message}`;
  }
  const ok = actual === expected;
  if (!ok) {
    failed += 1;
  }
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
}

console.log(failed === 0 ? '\nall cases passed' : `\n${failed} case(s) failed`);
process.exit(failed === 0 ? 0 : 1);
