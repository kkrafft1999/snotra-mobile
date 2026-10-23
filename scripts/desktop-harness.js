'use strict';

// The desktop's real channel (remote-channel.js) and dispatcher
// (remote-dispatcher.js) from a Snotra checkout, behind the relay stand-in,
// with a fake desktop port: three known folders, two of them opened to the
// phone. Opens one pairing, writes the relay config and the typed key to a
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
const desktopState = { active: SNOTRA, running: new Set(), listeners: new Set() };
const CHATS = [
  { chatId: 'c1', root: SNOTRA, title: 'Release notes for 1.4', updatedAt: now - 60_000, messageCount: 12 },
  { chatId: 'c2', root: SNOTRA, title: 'Why does the sandbox refuse git push?', updatedAt: now - 3_600_000, messageCount: 4 },
  { chatId: 'c3', root: WEBSITE, title: 'Tidy up the landing page', updatedAt: now - 86_400_000, messageCount: 7 },
  { chatId: 'c4', root: SECRET, title: 'Never shown', updatedAt: now, messageCount: 1 },
];

const desktop = {
  knownWorkspaces: async () => [SNOTRA, WEBSITE, SECRET],
  activeWorkspace: () => desktopState.active,
  listChats: async (roots) => CHATS.filter((c) => roots.includes(c.root)),
  loadChat: async (chatId) => CHATS.find((c) => c.chatId === chatId) ?? null,
  runningChats: () => desktopState.running,
  awaitingApproval: () => new Set(),
  pendingApprovals: () => [],
  respondToApproval: () => ({ ok: false, reason: 'not-found' }),
  subscribe: (listener) => { desktopState.listeners.add(listener); return () => desktopState.listeners.delete(listener); },
  startTurn: async () => ({ ok: false, reason: 'unavailable' }),
  stopChat: () => false,
  chatConfiguration: async () => ({}),
  // Opening the website starts a turn there, so that switching back is refused (R6).
  activateWorkspace: async (root) => {
    desktopState.active = root;
    if (root === WEBSITE) desktopState.running = new Set(['c3']);
    for (const listener of desktopState.listeners) listener({ kind: 'workspace' });
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
