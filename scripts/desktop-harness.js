'use strict';

// The desktop's real channel (remote-channel.js) and dispatcher
// (remote-dispatcher.js) from a Snotra checkout, behind the relay stand-in,
// with a fake desktop port: three known folders, two of them opened to the
// phone, and turns that stream a canned answer (a message with "slowly" in it
// streams long enough to be stopped; one with "approval" in it waits for a
// card first, which "the desktop answers" has the desktop deny). Opens one pairing, writes the relay config and the typed key to a
// fixture file, confirms the phone's claim once MAC_P verifies, then serves
// the channel until the phone unpairs. Node 24, nothing to install.
//
//   node scripts/desktop-harness.js ../snotra /tmp/snotra-desktop.json
//   TEST_RUNNER_SNOTRA_DESKTOP_HARNESS=/tmp/snotra-desktop.json \
//     xcodebuild test … -only-testing:SnotraMobileTests/DesktopLiveTests
//
// One harness, one pairing: start it again for the next run.

const path = require('node:path');
const fs = require('node:fs');

const [snotra, fixture] = process.argv.slice(2);
const req = (rel) => require(path.join(snotra, rel));
const { createRelayStandIn } = req('e2e/remote/relay-stand-in');
const { createKeys } = req('e2e/remote/reference-phone');
const { createFirebaseRelayAdapter } = req('src/main/remote/firebase-relay-adapter');
const { createRemoteChannelCryptoAdapter } = req('src/main/remote/channel-protocol');
const protocol = req('src/main/remote/pairing-protocol');
const { createRemoteChannel } = req('src/application/remote/remote-channel');
const { createRemoteDispatcher } = req('src/application/remote/remote-dispatcher');
const { translateMessage } = req('src/shared/i18n');

const SNOTRA = '/work/snotra', WEBSITE = '/work/website', SECRET = '/work/secret';
const now = Date.now();
const desktopState = { active: SNOTRA, running: new Set(), listeners: new Set(), turns: new Map() };
const chat = (chatId, root, title, ago, count) => ({
  chatId, root, title, updatedAt: now - ago,
  messages: Array.from({ length: count }, (_, i) => ({ role: i % 2 ? 'assistant' : 'user', content: i % 2 ? `Answer ${i}` : `Question ${i}` })),
});
const CHATS = [
  chat('c1', SNOTRA, 'Release notes for 1.4', 60_000, 12),
  chat('c2', SNOTRA, 'Why does the sandbox refuse git push?', 3_600_000, 4),
  chat('c3', WEBSITE, 'Tidy up the landing page', 86_400_000, 7),
  chat('c4', SECRET, 'Never shown', 0, 1),
];
/** What a turn answers, streamed in pieces: prose, a code block, non-ASCII text. */
const ANSWER = 'Here are the notes for **1.4**:\n\n```sh\nnpm run release -- 1.4.0\n```\n\nGrüße aus Snotra — fertig.';
/** The open approval cards, by request id, each with the turn that waits for it. */
const cards = new Map();
let cardCount = 0;
const emit = (activity) => { for (const listener of desktopState.listeners) listener(activity); };
const run = (chatId, runId, type, payload) => emit({ kind: 'run', chatId, runId, type, payload });

/** A card for a shell command, as the window's DTO; the turn goes on with the answer. */
function raiseCard(chatId, resume) {
  const requestId = `a-${++cardCount}`;
  const dto = {
    contractVersion: 1, requestId, chatId, tool: 'run_command', riskClasses: ['shell'],
    targets: [{ path: `${SNOTRA}/scripts/release.sh`, kind: 'file', exists: true }],
    reason: 'Runs a shell command in the workspace.', checkpoint: 'tool', mode: 'smart', sessionAllowed: false,
    preview: { kind: 'shell', text: 'npm run release -- 1.4.0', truncated: false, masked: false },
  };
  cards.set(requestId, { dto, resume });
  emit({ kind: 'approval', type: 'request', chatId, dto });
  console.log(`desktop: card ${requestId} in ${chatId}`);
  return requestId;
}

function settle(requestId, response, by) {
  const card = cards.get(requestId);
  if (!card) return false;
  cards.delete(requestId);
  emit({ kind: 'approval', type: 'resolved', requestId, chatId: card.dto.chatId, response, invalidated: false, reason: null, by });
  console.log(`desktop: card ${requestId} ${response} by ${by.kind}`);
  card.resume(response);
  return true;
}

/** A turn that streams its answer; `slow` ones take long enough to be stopped. */
function startTurn({ chatId, text, runId }) {
  let target = CHATS.find((c) => c.chatId === chatId);
  if (!target) {
    target = { chatId, root: desktopState.active, title: 'New chat', updatedAt: Date.now(), messages: [] };
    CHATS.push(target);
  }
  target.messages.push({ role: 'user', content: text });
  target.updatedAt = Date.now();
  desktopState.running.add(chatId);
  run(chatId, runId, 'progress', { type: 'chat-saved', ok: true });
  const pieces = text.includes('slowly') ? Array.from({ length: 200 }, (_, i) => `word${i} `) : ANSWER.match(/.{1,12}/gs);
  let streamed = '';
  let step = 0;
  let timer;
  const finish = (interrupted) => {
    clearInterval(timer);
    desktopState.turns.delete(chatId);
    target.messages.push({ role: 'assistant', content: streamed, toolTrace: [{ line: 'Read CHANGELOG.md', tool: 'read_file' }], ...(interrupted ? { interrupted: true } : {}) });
    target.updatedAt = Date.now();
    desktopState.running.delete(chatId);
    run(chatId, runId, 'progress', { type: 'run-end' });
    console.log(`desktop: turn in ${chatId} ${interrupted ? 'stopped' : 'done'}`);
  };
  const begin = () => { timer = setInterval(() => {
    if (step === 0) run(chatId, runId, 'tool-line', { callIndex: 0, phase: 'start', tool: 'read_file', line: 'Reading CHANGELOG.md' });
    if (step === 1) run(chatId, runId, 'tool-line', { callIndex: 0, phase: 'done', tool: 'read_file', line: 'Read CHANGELOG.md' });
    const piece = pieces[step];
    if (piece === undefined) return finish(false);
    streamed += piece;
    run(chatId, runId, 'delta', { text: piece });
    step += 1;
  }, 60); };
  if (text.includes('approval') || text.includes('the desktop answers')) {
    const requestId = raiseCard(chatId, (response) => {
      if (response !== 'deny') return begin();
      streamed = 'Not run: denied.';
      run(chatId, runId, 'delta', { text: streamed });
      finish(false);
    });
    if (text.includes('the desktop answers')) setTimeout(() => settle(requestId, 'deny', { kind: 'desktop' }), 1500);
  } else {
    begin();
  }
  desktopState.turns.set(chatId, () => finish(true));
  console.log(`desktop: turn in ${chatId} started`);
  return Promise.resolve({ ok: true });
}

const desktop = {
  knownWorkspaces: async () => [SNOTRA, WEBSITE, SECRET],
  activeWorkspace: () => desktopState.active,
  listChats: async (roots) => CHATS.filter((c) => roots.includes(c.root))
    .map(({ chatId, root, title, updatedAt, messages }) => ({ chatId, root, title, updatedAt, messageCount: messages.length })),
  loadChat: async (chatId) => structuredClone(CHATS.find((c) => c.chatId === chatId && c.messages.length > 0) ?? null),
  runningChats: () => desktopState.running,
  awaitingApproval: () => new Set([...cards.values()].map((card) => card.dto.chatId)),
  pendingApprovals: () => [...cards.values()].map((card) => card.dto),
  respondToApproval: (requestId, { response }, by) => {
    if (!cards.has(requestId)) return { ok: false, reason: 'not-found' };
    if (response !== 'allow-once' && response !== 'deny') return { ok: false, reason: 'refused' };
    settle(requestId, response, by);
    return { ok: true, response };
  },
  subscribe: (listener) => { desktopState.listeners.add(listener); return () => desktopState.listeners.delete(listener); },
  startTurn,
  stopChat: (chatId) => {
    const stop = desktopState.turns.get(chatId);
    if (!stop) return false;
    stop();
    return true;
  },
  chatConfiguration: async () => ({}),
  // Opening the website starts a turn there, so that switching back is refused (R6).
  activateWorkspace: async (root) => {
    desktopState.active = root;
    if (root === WEBSITE) desktopState.running.add('c3');
    emit({ kind: 'workspace' });
    console.log(`desktop: switched to ${path.basename(root)}`);
    return { ok: true };
  },
};
const releases = {
  isAvailable: () => true,
  list: async () => [{ workspaceId: 'W-snotra', root: SNOTRA }, { workspaceId: 'W-website', root: WEBSITE }],
  subscribe: () => () => {},
};

(async () => {
  const relay = createRelayStandIn();
  const config = await relay.start();
  const adapter = createFirebaseRelayAdapter({ endpoint: config });
  const desktopKeys = createKeys();
  const opened = await adapter.openPairing({ desktopKeys: desktopKeys.bundle, sign: desktopKeys.sign });
  const code = protocol.makeCode(opened.pairingId, protocol.drawSecret());
  fs.writeFileSync(fixture, JSON.stringify({ ...config, typedKey: protocol.displayCode(code) }, null, 2));
  console.log(`harness: relay ${config.relayUrl}, fixture ${fixture}`);

  let channel = null;
  let done = false;
  const finish = async (why) => {
    if (done) return;
    done = true;
    console.log(`harness: ${why}`);
    channel?.dispose();
    adapter.close();
    await relay.stop();
    process.exit(0);
  };

  let phoneKeys = null;
  adapter.watchChannel(opened.channelId, {
    onRecord: async (record) => {
      if (record?.status === 'pending' && !phoneKeys) {
        const ok = protocol.verifyPhoneMac({ code, channelId: opened.channelId, desktopKeys: desktopKeys.bundle, phoneKeys: record.phoneKeys, macP: record.macP });
        console.log(`desktop: claim seen, MAC_P ${ok ? 'verifies' : 'DOES NOT verify'}`);
        if (!ok) return finish('refused');
        phoneKeys = record.phoneKeys;
        const macD = protocol.toB64u(protocol.desktopMac({ code, channelId: opened.channelId, desktopKeys: desktopKeys.bundle, phoneKeys }));
        await adapter.confirmPairing(opened.channelId, macD);
      } else if (record?.status === 'paired' && !channel) {
        console.log('desktop: paired; starting the channel');
        const dispatcher = createRemoteDispatcher({ desktop, releases, word: translateMessage, deltaBatchMs: 150 });
        let connections = 0;
        channel = createRemoteChannel({
          relay: adapter,
          identity: {
            isAvailable: () => true,
            loadIdentity: async () => ({ keys: desktopKeys.bundle, sign: desktopKeys.sign, agree: desktopKeys.agree }),
            readPhone: async () => ({ channelId: opened.channelId, keys: phoneKeys, pairedAt: Date.now() }),
            savePhone: async () => {},
            forgetPhone: async () => {},
          },
          crypto: createRemoteChannelCryptoAdapter(),
          messages: dispatcher,
          word: translateMessage,
          appVersion: () => '0.0.0-harness',
          newConnectionId: () => `harness-${++connections}`,
          onGone: () => finish('the phone ended the pairing'),
          log: { warn: (line) => console.log(`desktop warn: ${line}`) },
        });
        channel.subscribe(({ connected }) => console.log(`desktop: phone ${connected ? 'connected' : 'not connected'}`));
        await channel.start();
      }
    },
    onError: (error) => console.log(`harness: meta stream error ${error?.message}`),
  });
  setTimeout(() => finish('timed out'), 5 * 60_000);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
