import http from 'k6/http';
import ws from 'k6/ws';
import exec from 'k6/execution';
import { fail, sleep } from 'k6';
import { Counter, Gauge, Rate, Trend } from 'k6/metrics';
import { boolEnv, boundedNumEnv, intEnv, parseOptionalInt } from './lib/env.js';
import {
  deriveWsUrl,
  hasResponseHeaderValue,
  makeLoginId,
  makeSeed,
  parseHost,
  pickRandom,
  safeJsonParse,
  stripTrailingSlash,
} from './lib/common.js';
import { buildStompFrame, parseStompFrames } from './lib/stomp.js';

const cfg = buildConfig();
const metrics = createMetrics();
let wsFailureLogs = 0;

export const options = {
  setupTimeout: cfg.setupTimeout,
  scenarios: buildScenarios(),
  thresholds: buildThresholds(),
};

export function setup() {
  const seed = makeSeed();
  const setupMode = cfg.skipSetup ? 'preset' : 'bootstrap';

  console.log(
    `[SETUP] baseUrl=${cfg.baseUrl} wsUrl=${cfg.wsUrl} groupId=${cfg.groupId} users=${cfg.userPoolSize} sellers=${cfg.sellerPoolSize} wsEnabled=${cfg.wsEnabled} mode=${setupMode}`,
  );

  if (cfg.groupId !== 1) {
    console.log('[SETUP] WARNING: 신규 유저는 groupId=1 자동가입 정책 기준. GROUP_ID=1 권장.');
  }

  const users = cfg.skipSetup ? loadPresetUsers(seed) : bootstrapUsers(seed);
  if (users.length < 3) {
    fail(`[SETUP] Not enough users. users=${users.length} mode=${setupMode}`);
  }

  const { sellers, buyers, userById } = splitUsers(users);
  const seeded = cfg.skipSeedPosts ? createEmptySeedState(sellers) : seedPostsForSellers(seed, sellers);
  if (!cfg.skipSeedPosts && seeded.postIds.length === 0) {
    fail(`[SETUP] Seed post creation failed. groupId=${cfg.groupId}`);
  }

  let wsAssignments = [];
  if (cfg.wsEnabled) {
    if (cfg.skipSeedChatrooms) {
      console.log('[SETUP] SKIP_SEED_CHATROOMS=true, WS assignments bootstrap skipped.');
    } else {
      if (seeded.postIds.length === 0) {
        fail('[SETUP] WS bootstrap needs seeded posts. Disable SKIP_SEED_POSTS or set SKIP_SEED_CHATROOMS=true.');
      }

      wsAssignments = seedChatrooms(buyers, seeded.postIds);
      if (wsAssignments.length === 0) {
        fail('[SETUP] Failed to create WS assignments (chatrooms).');
      }
    }
  }

  console.log(
    `[SETUP] users=${users.length} sellers=${sellers.length} buyers=${buyers.length} posts=${seeded.postIds.length} wsAssignments=${wsAssignments.length}`,
  );

  return {
    seed,
    groupId: cfg.groupId,
    users,
    sellers,
    buyers,
    userById,
    postIds: seeded.postIds,
    sellerIds: seeded.sellerIds,
    sellerPostMap: seeded.sellerPostMap,
    postOwners: seeded.postOwners,
    wsAssignments,
  };
}

export function httpMixedScenario(state) {
  const action = pickAction(state);

  if (action === 'read_list') {
    doReadList(state);
    return;
  }
  if (action === 'read_detail') {
    doReadDetail(state);
    return;
  }
  if (action === 'read_profile') {
    doReadProfile(state);
    return;
  }
  if (action === 'read_messages') {
    doReadMessages(state);
    return;
  }
  if (action === 'create_post') {
    doCreatePost(state);
    return;
  }
  if (action === 'update_post') {
    doUpdatePost(state);
    return;
  }
  if (action === 'patch_status') {
    doPatchStatus(state);
    return;
  }
  if (action === 'delete_post') {
    doDeletePost(state);
    return;
  }

  doCreateChatroom(state);
}

export function wsChatScenario(state) {
  if (!cfg.wsEnabled) {
    return;
  }

  if (!state.wsAssignments || state.wsAssignments.length === 0) {
    metrics.wsSessionSuccessRate.add(false);
    metrics.wsErrors.add(1);
    return;
  }

  const assignment = state.wsAssignments[(exec.vu.idInTest - 1) % state.wsAssignments.length];
  const authHeader = `Bearer ${assignment.token}`;
  const subscribeDestination = `/topic/chatrooms/${assignment.chatroomId}`;
  const wsConnectParams = {
    headers: {
      'Sec-WebSocket-Protocol': 'v12.stomp',
    },
  };
  if (cfg.wsHandshakeAuthHeader) {
    wsConnectParams.headers.Authorization = authHeader;
  }

  let connected = false;
  let hadError = false;
  let membershipId = null;
  let latestMessageId = null;

  const response = ws.connect(cfg.wsUrl, wsConnectParams, function (socket) {
    socket.on('open', () => {
      metrics.wsActiveConnections.add(1);
      sendStompFrame(socket, 'CONNECT', {
        'accept-version': '1.2',
        host: cfg.wsHost,
        Authorization: authHeader,
        'heart-beat': '10000,10000',
      });
      metrics.wsFramesSent.add(1);
    });

    socket.on('message', (raw) => {
      metrics.wsFramesReceived.add(1);
      const frames = parseStompFrames(raw);

      for (const frame of frames) {
        if (frame.command === 'CONNECTED') {
          connected = true;

          sendStompFrame(socket, 'SUBSCRIBE', {
            id: `sub-${exec.vu.idInTest}-${exec.vu.iterationInScenario}`,
            destination: subscribeDestination,
            Authorization: authHeader,
          });
          sendStompFrame(
            socket,
            'SEND',
            {
              destination: '/app/chat/join',
              'content-type': 'application/json',
              Authorization: authHeader,
            },
            JSON.stringify({ chatroomId: assignment.chatroomId }),
          );
          metrics.wsFramesSent.add(2);
          continue;
        }

        if (frame.command === 'MESSAGE') {
          const payload = safeJsonParse(frame.body);
          if (!payload) {
            continue;
          }

          if (Number(payload.chatroomId) === Number(assignment.chatroomId) && payload.membershipId) {
            membershipId = Number(payload.membershipId);
          }

          if (payload.messageId) {
            latestMessageId = String(payload.messageId);
          }
          continue;
        }

        if (frame.command === 'ERROR') {
          hadError = true;
          metrics.wsErrors.add(1);
          metrics.wsMessageSendSuccessRate.add(false);
          logWsFailure(`stomp ERROR frame: ${String(frame.body || '').slice(0, 180)}`);
        }
      }
    });

    socket.on('error', (err) => {
      hadError = true;
      metrics.wsErrors.add(1);
      metrics.wsMessageSendSuccessRate.add(false);
      logWsFailure(`socket error: ${String(err || 'unknown')}`);
    });

    socket.setInterval(() => {
      if (!connected) {
        return;
      }

      if (!membershipId) {
        sendStompFrame(
          socket,
          'SEND',
          {
            destination: '/app/chat/join',
            'content-type': 'application/json',
            Authorization: authHeader,
          },
          JSON.stringify({ chatroomId: assignment.chatroomId }),
        );
        metrics.wsFramesSent.add(1);
        return;
      }

      sendStompFrame(
        socket,
        'SEND',
        {
          destination: '/app/chat/send',
          'content-type': 'application/json',
          Authorization: authHeader,
        },
        JSON.stringify({
          chatroomId: assignment.chatroomId,
          membershipId,
          message: `load-test-ws-${Date.now()}-${Math.floor(Math.random() * 10000)}`,
        }),
      );
      metrics.wsFramesSent.add(1);
      metrics.wsMessagesSent.add(1);
      metrics.wsMessageSendSuccessRate.add(true);

      if (latestMessageId && Math.random() < 0.25) {
        sendStompFrame(
          socket,
          'SEND',
          {
            destination: '/app/chat/read',
            'content-type': 'application/json',
            Authorization: authHeader,
          },
          JSON.stringify({
            chatroomId: assignment.chatroomId,
            membershipId,
            readMessageId: latestMessageId,
          }),
        );
        metrics.wsFramesSent.add(1);
      }
    }, cfg.wsMessageIntervalMs);

    socket.setTimeout(() => socket.close(), cfg.wsSessionSec * 1000);

    socket.on('close', () => {
      metrics.wsActiveConnections.add(-1);
      if (!connected) {
        logWsFailure('socket closed before STOMP CONNECTED frame');
      }
      const ok = connected && !hadError && (!cfg.wsSuccessRequiresMembership || membershipId !== null);
      metrics.wsSessionSuccessRate.add(ok);
    });
  });

  if (!response || response.status !== 101) {
    const statusTag = response && response.status ? String(response.status) : 'none';
    metrics.wsConnectFailures.add(1, { status: statusTag });
    metrics.wsErrors.add(1);
    metrics.wsSessionSuccessRate.add(false);
    metrics.wsMessageSendSuccessRate.add(false);
    logWsFailure(
      `connect failed status=${statusTag} body=${response && response.body ? String(response.body).slice(0, 180) : ''}`,
    );
    sleep(0.3);
  }
}

function doReadList(state) {
  const user = pickRandom(state.users);
  const res = http.get(`${cfg.baseUrl}/groups/${state.groupId}/posts`, authParams(user.token));
  recordRead('read_list', 'GET', res, res.status >= 200 && res.status < 300);
}

function doReadDetail(state) {
  const user = pickRandom(state.users);
  const postId = pickRandom(state.postIds);

  if (!postId) {
    doReadList(state);
    return;
  }

  const res = http.get(`${cfg.baseUrl}/groups/${state.groupId}/posts/${postId}`, authParams(user.token));
  recordRead('read_detail', 'GET', res, (res.status >= 200 && res.status < 300) || res.status === 404);
}

function doReadProfile(state) {
  const user = pickRandom(state.users);
  const res = http.get(`${cfg.baseUrl}/users/me`, authParams(user.token));
  recordRead('read_profile', 'GET', res, res.status >= 200 && res.status < 300);
}

function doReadMessages(state) {
  const assignment = pickRandom(state.wsAssignments);
  if (!assignment) {
    doReadDetail(state);
    return;
  }

  const res = http.get(
    `${cfg.baseUrl}/posts/${assignment.postId}/chatrooms/${assignment.chatroomId}/messages`,
    authParams(assignment.token),
  );
  recordRead('read_messages', 'GET', res, (res.status >= 200 && res.status < 300) || res.status === 404);
}

function doCreatePost(state) {
  const seller = pickRandom(state.sellers);
  if (!seller) {
    return;
  }

  const nonce = `${Date.now()}-${Math.floor(Math.random() * 10000)}`;
  const res = createPost(
    state,
    seller,
    `load-test-create-${nonce}`,
    `load-test create ${nonce}`,
    `load-test/create/${nonce}.jpg`,
    'create_post',
  );

  if (res.status === 201) {
    const postId = Number(res.json('postId'));
    if (!Number.isNaN(postId)) {
      addOwnedPost(state, seller.userId, postId);
    }
  }
}

function doUpdatePost(state) {
  const owned = pickOwnedPost(state);
  if (!owned) {
    doCreatePost(state);
    return;
  }

  const nonce = `${Date.now()}-${Math.floor(Math.random() * 10000)}`;
  const res = http.put(
    `${cfg.baseUrl}/groups/${state.groupId}/posts/${owned.postId}`,
    JSON.stringify({
      title: `load-test-update-${nonce}`.slice(0, 50),
      content: `load-test update content ${nonce}`,
      imageUrls: [{ postImageId: null, imageUrl: `load-test/update/${nonce}.jpg` }],
      rentalFee: 1000 + Math.floor(Math.random() * 9000),
      feeUnit: Math.random() < 0.5 ? 'DAY' : 'HOUR',
    }),
    authJsonParams(owned.seller.token),
  );

  const ok = res.status === 200 || res.status === 404;
  recordWrite('update_post', 'PUT', res, ok);

  if (res.status === 404) {
    removeOwnedPost(state, owned.seller.userId, owned.postId);
  }
}

function doPatchStatus(state) {
  const owned = pickOwnedPost(state);
  if (!owned) {
    doCreatePost(state);
    return;
  }

  const res = http.patch(
    `${cfg.baseUrl}/groups/${state.groupId}/posts/${owned.postId}`,
    JSON.stringify({ status: Math.random() < 0.5 ? 'AVAILABLE' : 'RENTED_OUT' }),
    authJsonParams(owned.seller.token),
  );

  const ok = res.status === 200 || res.status === 404;
  recordWrite('patch_status', 'PATCH', res, ok);

  if (res.status === 404) {
    removeOwnedPost(state, owned.seller.userId, owned.postId);
  }
}

function doDeletePost(state) {
  const owned = pickOwnedPost(state);
  if (!owned) {
    doCreatePost(state);
    return;
  }

  const res = http.del(
    `${cfg.baseUrl}/groups/${state.groupId}/posts/${owned.postId}`,
    null,
    authParams(owned.seller.token),
  );

  const ok = res.status === 204 || res.status === 404;
  recordWrite('delete_post', 'DELETE', res, ok);

  if (res.status === 204 || res.status === 404) {
    removeOwnedPost(state, owned.seller.userId, owned.postId);
  }

  if (cfg.replaceAfterDelete && res.status === 204) {
    const nonce = `${Date.now()}-${Math.floor(Math.random() * 10000)}`;
    const replaceRes = createPost(
      state,
      owned.seller,
      `load-test-replace-${nonce}`,
      `load-test replace content ${nonce}`,
      `load-test/replace/${nonce}.jpg`,
      'replace_post',
    );

    if (replaceRes.status === 201) {
      const newPostId = Number(replaceRes.json('postId'));
      if (!Number.isNaN(newPostId)) {
        addOwnedPost(state, owned.seller.userId, newPostId);
      }
    }
  }
}

function doCreateChatroom(state) {
  const buyer = pickRandom(state.buyers) || pickRandom(state.users);
  const postId = pickRandom(state.postIds);

  if (!buyer || !postId) {
    return;
  }

  const res = http.post(`${cfg.baseUrl}/posts/${postId}/chatrooms`, null, authParams(buyer.token));
  const ok = res.status === 201 || res.status === 409;
  recordWrite('create_chatroom', 'POST', res, ok);

  if (res.status === 201) {
    const chatroomId = Number(res.json('chatroomId'));
    if (!Number.isNaN(chatroomId)) {
      state.wsAssignments.push({
        userId: buyer.userId,
        token: buyer.token,
        postId,
        chatroomId,
      });
    }
  }
}

function createPost(state, seller, title, content, imagePath, actionTag) {
  const res = http.post(
    `${cfg.baseUrl}/groups/${state.groupId}/posts`,
    JSON.stringify({
      title: title.slice(0, 50),
      content,
      imageUrls: [imagePath],
      rentalFee: 1000 + Math.floor(Math.random() * 9000),
      feeUnit: Math.random() < 0.5 ? 'DAY' : 'HOUR',
    }),
    authJsonParams(seller.token),
  );

  recordWrite(actionTag, 'POST', res, res.status === 201);
  return res;
}

function createEmptySeedState(sellers) {
  const sellerIds = [];
  const sellerPostMap = {};
  for (const seller of sellers) {
    sellerIds.push(seller.userId);
    sellerPostMap[String(seller.userId)] = [];
  }

  return {
    postIds: [],
    sellerIds,
    sellerPostMap,
    postOwners: {},
  };
}

function loadPresetUsers(seed) {
  const fromJsonEnv = parsePresetUsersJson(cfg.presetUsersJson);
  if (fromJsonEnv.length > 0) {
    console.log(`[SETUP] preset users source=PRESET_USERS_JSON count=${fromJsonEnv.length}`);
    metrics.bootstrapUsersLoggedIn.add(fromJsonEnv.length);
    return fromJsonEnv;
  }

  const fromJsonFile = parsePresetUsersJson(cfg.presetUsersFileContent);
  if (fromJsonFile.length > 0) {
    console.log(`[SETUP] preset users source=PRESET_USERS_FILE(${cfg.presetUsersFilePath}) count=${fromJsonFile.length}`);
    metrics.bootstrapUsersLoggedIn.add(fromJsonFile.length);
    return fromJsonFile;
  }

  const fromTokenList = parsePresetTokenList(cfg.presetTokenList, seed);
  if (fromTokenList.length > 0) {
    console.log(`[SETUP] preset users source=PRESET_TOKEN_LIST count=${fromTokenList.length}`);
    metrics.bootstrapUsersLoggedIn.add(fromTokenList.length);
    return fromTokenList;
  }

  fail('[SETUP] SKIP_SETUP=true but no usable preset users. Set PRESET_USERS_JSON, PRESET_USERS_FILE, or PRESET_TOKEN_LIST.');
}

function parsePresetUsersJson(raw) {
  if (!raw || String(raw).trim() === '') {
    return [];
  }

  const parsed = safeJsonParse(raw);
  if (!Array.isArray(parsed)) {
    return [];
  }

  const users = [];
  for (let i = 0; i < parsed.length; i += 1) {
    const row = parsed[i];
    if (!row || typeof row !== 'object') {
      continue;
    }

    const token = String(row.token || row.accessToken || '').trim();
    if (!token) {
      continue;
    }

    const rawUserId = Number(row.userId || row.id || i + 1);
    const userId = Number.isFinite(rawUserId) && rawUserId > 0 ? rawUserId : i + 1;
    const loginId = String(row.loginId || row.username || `preset-${i}`).trim() || `preset-${i}`;
    users.push({ loginId, userId, token });
  }

  return users;
}

function parsePresetTokenList(raw, seed) {
  if (!raw || String(raw).trim() === '') {
    return [];
  }

  const tokens = String(raw)
    .split(/[\s,]+/)
    .map((token) => token.trim())
    .filter((token) => token.length > 0);

  const users = [];
  for (let i = 0; i < tokens.length; i += 1) {
    users.push({
      loginId: `preset-${seed}-${i}`,
      userId: i + 1,
      token: tokens[i],
    });
  }

  return users;
}

function bootstrapUsers(seed) {
  const users = [];

  for (let i = 0; i < cfg.userPoolSize; i += 1) {
    const loginId = makeLoginId(seed, i);

    const joinRes = http.post(
      `${cfg.baseUrl}/users`,
      JSON.stringify({ loginId, password: cfg.userPassword }),
      jsonParams(),
    );

    if (joinRes.status === 200) {
      metrics.bootstrapUsersCreated.add(1);
    } else if (joinRes.status >= 500) {
      metrics.bootstrapFailures.add(1);
    }

    const loginRes = http.post(
      `${cfg.baseUrl}/auth/login`,
      JSON.stringify({ loginId, password: cfg.userPassword }),
      jsonParams(),
    );

    if (loginRes.status !== 200) {
      metrics.bootstrapFailures.add(1);
      continue;
    }

    const token = loginRes.json('accessToken');
    const userId = Number(loginRes.json('userId'));
    if (!token || Number.isNaN(userId)) {
      metrics.bootstrapFailures.add(1);
      continue;
    }

    metrics.bootstrapUsersLoggedIn.add(1);
    users.push({ loginId, userId, token });
  }

  return users;
}

function splitUsers(users) {
  const sellerCount = Math.max(1, Math.min(cfg.sellerPoolSize, users.length - 1));
  const sellers = users.slice(0, sellerCount);
  const buyers = users.slice(sellerCount);

  if (buyers.length === 0) {
    fail('[SETUP] Need at least one buyer user. Increase USER_POOL_SIZE.');
  }

  const userById = {};
  for (const user of users) {
    userById[String(user.userId)] = user;
  }

  return { sellers, buyers, userById };
}

function seedPostsForSellers(seed, sellers) {
  const postIds = [];
  const sellerIds = [];
  const sellerPostMap = {};
  const postOwners = {};

  for (let sellerIndex = 0; sellerIndex < sellers.length; sellerIndex += 1) {
    const seller = sellers[sellerIndex];
    sellerIds.push(seller.userId);
    sellerPostMap[String(seller.userId)] = [];

    for (let postIndex = 0; postIndex < cfg.seedPostsPerSeller; postIndex += 1) {
      const res = http.post(
        `${cfg.baseUrl}/groups/${cfg.groupId}/posts`,
        JSON.stringify({
          title: `load-test-seed-${seed}-${sellerIndex}-${postIndex}`.slice(0, 50),
          content: `load-test seed content ${seed} seller=${sellerIndex} idx=${postIndex}`,
          imageUrls: [`load-test/seed/${seed}/${sellerIndex}-${postIndex}.jpg`],
          rentalFee: 1000 + postIndex,
          feeUnit: postIndex % 2 === 0 ? 'DAY' : 'HOUR',
        }),
        authJsonParams(seller.token),
      );

      if (res.status !== 201) {
        metrics.bootstrapFailures.add(1);
        continue;
      }

      const postId = Number(res.json('postId'));
      if (Number.isNaN(postId)) {
        metrics.bootstrapFailures.add(1);
        continue;
      }

      postIds.push(postId);
      sellerPostMap[String(seller.userId)].push(postId);
      postOwners[String(postId)] = seller.userId;
    }
  }

  return { postIds, sellerIds, sellerPostMap, postOwners };
}

function seedChatrooms(buyers, postIds) {
  const assignments = [];
  const targetCount = Math.min(cfg.wsUserPoolSize, buyers.length);

  for (let i = 0; i < targetCount; i += 1) {
    const buyer = buyers[i];
    let created = false;

    for (let attempt = 0; attempt < Math.min(10, postIds.length); attempt += 1) {
      const postId = postIds[(i + attempt) % postIds.length];
      const res = http.post(`${cfg.baseUrl}/posts/${postId}/chatrooms`, null, authParams(buyer.token));

      if (res.status === 201) {
        const chatroomId = Number(res.json('chatroomId'));
        if (!Number.isNaN(chatroomId)) {
          assignments.push({ userId: buyer.userId, token: buyer.token, postId, chatroomId });
          created = true;
          break;
        }
      }

      if (res.status >= 500) {
        metrics.bootstrapFailures.add(1);
      }
    }

    if (!created) {
      metrics.bootstrapFailures.add(1);
    }
  }

  return assignments;
}

function pickAction(state) {
  const weights = [
    ['read_list', cfg.actionReadListRatio],
    ['read_detail', cfg.actionReadDetailRatio],
    ['read_profile', cfg.actionReadProfileRatio],
    ['read_messages', state.wsAssignments.length > 0 ? cfg.actionReadMessagesRatio : 0],
    ['create_post', cfg.actionCreatePostRatio],
    ['update_post', hasOwnedPost(state) ? cfg.actionUpdatePostRatio : 0],
    ['patch_status', hasOwnedPost(state) ? cfg.actionPatchStatusRatio : 0],
    ['delete_post', hasOwnedPost(state) ? cfg.actionDeletePostRatio : 0],
    ['create_chatroom', state.postIds.length > 0 ? cfg.actionCreateChatroomRatio : 0],
  ];

  const total = weights.reduce((sum, [, weight]) => sum + weight, 0);
  if (total <= 0) {
    return 'read_list';
  }

  let point = Math.random() * total;
  for (const [action, weight] of weights) {
    if (weight <= 0) {
      continue;
    }
    point -= weight;
    if (point <= 0) {
      return action;
    }
  }

  return 'read_list';
}

function hasOwnedPost(state) {
  for (const sellerId of state.sellerIds) {
    const posts = state.sellerPostMap[String(sellerId)] || [];
    if (posts.length > 0) {
      return true;
    }
  }
  return false;
}

function pickOwnedPost(state) {
  const sellerIds = [];

  for (const sellerId of state.sellerIds) {
    const posts = state.sellerPostMap[String(sellerId)] || [];
    if (posts.length > 0) {
      sellerIds.push(sellerId);
    }
  }

  if (sellerIds.length === 0) {
    return null;
  }

  const sellerId = pickRandom(sellerIds);
  const posts = state.sellerPostMap[String(sellerId)] || [];
  const postId = pickRandom(posts);
  const seller = state.userById[String(sellerId)];

  if (!seller || !postId) {
    return null;
  }

  return { seller, postId };
}

function addOwnedPost(state, sellerUserId, postId) {
  const sellerKey = String(sellerUserId);

  if (!state.sellerPostMap[sellerKey]) {
    state.sellerPostMap[sellerKey] = [];
  }
  if (!state.sellerPostMap[sellerKey].includes(postId)) {
    state.sellerPostMap[sellerKey].push(postId);
  }
  if (!state.postIds.includes(postId)) {
    state.postIds.push(postId);
  }

  state.postOwners[String(postId)] = sellerUserId;
}

function removeOwnedPost(state, sellerUserId, postId) {
  const sellerKey = String(sellerUserId);

  if (state.sellerPostMap[sellerKey]) {
    state.sellerPostMap[sellerKey] = state.sellerPostMap[sellerKey].filter((id) => id !== postId);
  }
  state.postIds = state.postIds.filter((id) => id !== postId);
  delete state.postOwners[String(postId)];
}

function recordRead(action, method, res, ok) {
  metrics.actionRequests.add(1, { action, method, kind: 'read' });
  metrics.actionLatency.add(res.timings.duration, { action, method, kind: 'read' });
  metrics.actionSuccessRate.add(ok, { action, kind: 'read' });

  metrics.httpReadRequests.add(1, { action, method });
  metrics.httpReadLatency.add(res.timings.duration, { action, method });
  metrics.httpReadSuccessRate.add(ok, { action });

  if (!ok) {
    metrics.actionFailures.add(1, { action, method, kind: 'read' });
  }

  metrics.downtimeErrorRate.add(isDowntimeLike(res), { action, method, kind: 'read' });
}

function recordWrite(action, method, res, ok) {
  const writeClassification = classifyWriteResult(res, ok);

  metrics.actionRequests.add(1, { action, method, kind: 'write' });
  metrics.actionLatency.add(res.timings.duration, { action, method, kind: 'write' });
  metrics.actionSuccessRate.add(ok, { action, kind: 'write' });

  metrics.httpWriteRequests.add(1, { action, method });
  metrics.httpWriteLatency.add(res.timings.duration, { action, method });
  metrics.httpWriteSuccessRate.add(ok, { action });
  metrics.writeBlockedRate.add(writeClassification.blocked, { action, method });
  metrics.intentionalWriteBlockedRate.add(writeClassification.intentional, { action, method });
  metrics.unexpectedWriteFailureRate.add(writeClassification.unexpected, { action, method });

  if (!ok) {
    metrics.actionFailures.add(1, { action, method, kind: 'write' });
  }

  metrics.downtimeErrorRate.add(writeClassification.unplannedDowntimeLike, { action, method, kind: 'write' });
}

function isDowntimeLike(res) {
  return res.status === 0 || res.status >= 500;
}

function isIntentionalWriteBlocked(res) {
  return (
    res &&
    res.status === 503 &&
    hasResponseHeaderValue(res, cfg.writeBlockHeaderName, cfg.writeBlockHeaderValue)
  );
}

function classifyWriteResult(res, writeOk) {
  if (writeOk) {
    return {
      blocked: false,
      intentional: false,
      unexpected: false,
      unplannedDowntimeLike: false,
    };
  }

  const intentional = isIntentionalWriteBlocked(res);
  const unexpected = !intentional;
  return {
    blocked: true,
    intentional,
    unexpected,
    unplannedDowntimeLike: unexpected && isDowntimeLike(res),
  };
}

function createMetrics() {
  return {
    bootstrapUsersCreated: new Counter('bootstrap_users_created'),
    bootstrapUsersLoggedIn: new Counter('bootstrap_users_logged_in'),
    bootstrapFailures: new Counter('bootstrap_failures'),

    actionRequests: new Counter('action_requests'),
    actionFailures: new Counter('action_failures'),
    actionLatency: new Trend('action_latency', true),
    actionSuccessRate: new Rate('action_success_rate'),

    httpReadRequests: new Counter('http_read_requests'),
    httpWriteRequests: new Counter('http_write_requests'),
    httpReadSuccessRate: new Rate('http_read_success_rate'),
    httpWriteSuccessRate: new Rate('http_write_success_rate'),
    httpReadLatency: new Trend('http_read_latency', true),
    httpWriteLatency: new Trend('http_write_latency', true),
    writeBlockedRate: new Rate('write_blocked_rate'),
    intentionalWriteBlockedRate: new Rate('intentional_write_blocked_rate'),
    unexpectedWriteFailureRate: new Rate('unexpected_write_failure_rate'),
    downtimeErrorRate: new Rate('downtime_error_rate'),

    wsSessionSuccessRate: new Rate('ws_session_success_rate'),
    wsMessageSendSuccessRate: new Rate('ws_message_send_success_rate'),
    wsFramesSent: new Counter('ws_frames_sent'),
    wsFramesReceived: new Counter('ws_frames_received'),
    wsMessagesSent: new Counter('ws_messages_sent'),
    wsErrors: new Counter('ws_errors'),
    wsConnectFailures: new Counter('ws_connect_failures'),
    wsActiveConnections: new Gauge('ws_active_connections'),
  };
}

function logWsFailure(message) {
  if (wsFailureLogs >= 10) {
    return;
  }
  wsFailureLogs += 1;
  console.log(`[WS] ${message}`);
}

function sendStompFrame(socket, command, headers, body) {
  const frame = buildStompFrame(command, headers, body);
  if (typeof socket.sendBinary === 'function') {
    const bytes = new Uint8Array(frame.length);
    for (let i = 0; i < frame.length; i += 1) {
      bytes[i] = frame.charCodeAt(i) & 0xff;
    }
    socket.sendBinary(bytes.buffer);
    return;
  }
  socket.send(frame);
}

function buildScenarios() {
  const scenarios = {
    http_mix: {
      executor: 'ramping-arrival-rate',
      exec: 'httpMixedScenario',
      startRate: cfg.httpRpsMin,
      timeUnit: '1s',
      preAllocatedVUs: cfg.httpPreAllocatedVus,
      maxVUs: cfg.httpMaxVus,
      stages: [
        { duration: cfg.httpStage1, target: cfg.httpRpsMin },
        { duration: cfg.httpStage2, target: cfg.httpRpsMid },
        { duration: cfg.httpStage3, target: cfg.httpRpsMax },
      ],
      tags: { workload: 'http-mix' },
    },
  };

  if (cfg.wsEnabled) {
    scenarios.ws_chat_heavy = {
      executor: 'constant-vus',
      exec: 'wsChatScenario',
      vus: cfg.wsVus,
      duration: cfg.wsDuration,
      tags: { workload: 'ws-chat' },
    };
  }

  return scenarios;
}

function buildThresholds() {
  if (!cfg.strictThresholds) {
    const relaxed = {
      'http_req_failed{scenario:http_mix}': ['rate<0.50'],
      http_read_success_rate: ['rate>0.50'],
      http_write_success_rate: ['rate>0.50'],
      write_blocked_rate: ['rate<0.50'],
      unexpected_write_failure_rate: ['rate<0.50'],
      downtime_error_rate: ['rate<0.20'],
    };

    if (cfg.wsEnabled) {
      relaxed.ws_session_success_rate = ['rate>=0.00'];
    }

    return relaxed;
  }

  const strict = {
    'http_req_duration{scenario:http_mix}': [`p(95)<${cfg.httpP95ThresholdMs}`],
    'http_req_failed{scenario:http_mix}': [`rate<${cfg.maxErrorRate}`],
    http_read_success_rate: ['rate>0.95'],
    http_write_success_rate: ['rate>0.95'],
    write_blocked_rate: [`rate<${cfg.maxWriteBlockRate}`],
    unexpected_write_failure_rate: [`rate<${cfg.maxUnexpectedWriteFailureRate}`],
    downtime_error_rate: [`rate<${cfg.maxDowntimeErrorRate}`],
  };

  if (cfg.wsEnabled) {
    strict.ws_session_success_rate = ['rate>0.90'];
    strict.ws_message_send_success_rate = ['rate>0.85'];
  }

  return strict;
}

function buildConfig() {
  const baseUrl = stripTrailingSlash(__ENV.TARGET_URL || 'http://test.billages.com/api');
  const wsUrl = stripTrailingSlash(__ENV.WS_URL || deriveWsUrl(baseUrl));
  const presetUsersFilePath = String(__ENV.PRESET_USERS_FILE || '').trim();
  let presetUsersFileContent = '';
  if (presetUsersFilePath) {
    try {
      presetUsersFileContent = open(presetUsersFilePath);
    } catch (err) {
      console.log(`[SETUP] WARNING: failed to open PRESET_USERS_FILE path=${presetUsersFilePath} err=${String(err)}`);
    }
  }

  const wsVus = intEnv('WS_VUS', 120);
  const userPoolSize = intEnv('USER_POOL_SIZE', 120);
  const httpRpsMin = intEnv('HTTP_RPS_MIN', 300);
  const httpRpsMax = intEnv('HTTP_RPS_MAX', 600);
  const maxWriteBlockRate = boundedNumEnv('MAX_WRITE_BLOCK_RATE', 0.01, 0, 1);

  return {
    setupTimeout: __ENV.SETUP_TIMEOUT || '10m',
    baseUrl,
    wsUrl,
    wsHost: parseHost(wsUrl),
    groupId: parseOptionalInt(__ENV.GROUP_ID) || 1,
    skipSetup: boolEnv('SKIP_SETUP', false),
    skipSeedPosts: boolEnv('SKIP_SEED_POSTS', false),
    skipSeedChatrooms: boolEnv('SKIP_SEED_CHATROOMS', false),
    presetUsersJson: __ENV.PRESET_USERS_JSON || '',
    presetUsersFilePath,
    presetUsersFileContent,
    presetTokenList: __ENV.PRESET_TOKEN_LIST || '',

    userPoolSize,
    sellerPoolSize: Math.max(
      1,
      Math.min(userPoolSize - 1, intEnv('SELLER_POOL_SIZE', Math.max(10, Math.floor(userPoolSize * 0.3)))),
    ),
    userPassword: __ENV.USER_PASSWORD || 'Qwer1234!',
    seedPostsPerSeller: intEnv('SEED_POSTS_PER_SELLER', 6),

    actionReadListRatio: boundedNumEnv('ACTION_READ_LIST_RATIO', 0.25, 0, 1),
    actionReadDetailRatio: boundedNumEnv('ACTION_READ_DETAIL_RATIO', 0.2, 0, 1),
    actionReadProfileRatio: boundedNumEnv('ACTION_READ_PROFILE_RATIO', 0.1, 0, 1),
    actionReadMessagesRatio: boundedNumEnv('ACTION_READ_MESSAGES_RATIO', 0.05, 0, 1),
    actionCreatePostRatio: boundedNumEnv('ACTION_CREATE_POST_RATIO', 0.15, 0, 1),
    actionUpdatePostRatio: boundedNumEnv('ACTION_UPDATE_POST_RATIO', 0.1, 0, 1),
    actionPatchStatusRatio: boundedNumEnv('ACTION_PATCH_STATUS_RATIO', 0.08, 0, 1),
    actionDeletePostRatio: boundedNumEnv('ACTION_DELETE_POST_RATIO', 0.02, 0, 1),
    actionCreateChatroomRatio: boundedNumEnv('ACTION_CREATE_CHATROOM_RATIO', 0.05, 0, 1),

    replaceAfterDelete: boolEnv('REPLACE_AFTER_DELETE', true),

    httpRpsMin,
    httpRpsMax,
    httpRpsMid: intEnv('HTTP_RPS_MID', Math.round((httpRpsMin + httpRpsMax) / 2)),
    httpStage1: __ENV.HTTP_STAGE_1 || '5m',
    httpStage2: __ENV.HTTP_STAGE_2 || '10m',
    httpStage3: __ENV.HTTP_STAGE_3 || '10m',
    httpPreAllocatedVus: intEnv('HTTP_PRE_ALLOCATED_VUS', 600),
    httpMaxVus: intEnv('HTTP_MAX_VUS', 2000),

    wsEnabled: boolEnv('ENABLE_WS', true) && wsVus > 0,
    wsVus,
    wsDuration: __ENV.WS_DURATION || '25m',
    wsSessionSec: intEnv('WS_SESSION_SEC', 20),
    wsMessageIntervalMs: intEnv('WS_MESSAGE_INTERVAL_MS', 500),
    wsUserPoolSize: intEnv(
      'WS_USER_POOL_SIZE',
      Math.max(10, Math.min(wsVus, userPoolSize - 1)),
    ),
    wsSuccessRequiresMembership: boolEnv('WS_SUCCESS_REQUIRES_MEMBERSHIP', false),
    wsHandshakeAuthHeader: boolEnv('WS_HANDSHAKE_AUTH_HEADER', false),

    strictThresholds: boolEnv('STRICT_THRESHOLDS', true),
    maxErrorRate: boundedNumEnv('MAX_ERROR_RATE', 0.001, 0, 1),
    maxWriteBlockRate,
    maxUnexpectedWriteFailureRate: boundedNumEnv('MAX_UNEXPECTED_WRITE_FAILURE_RATE', maxWriteBlockRate, 0, 1),
    maxDowntimeErrorRate: boundedNumEnv('MAX_DOWNTIME_ERROR_RATE', 0.01, 0, 1),
    httpP95ThresholdMs: intEnv('HTTP_P95_THRESHOLD_MS', 500),
    writeBlockHeaderName: __ENV.WRITE_BLOCK_HEADER_NAME || 'X-Migration-Write-Block',
    writeBlockHeaderValue: __ENV.WRITE_BLOCK_HEADER_VALUE || 'soft-freeze',
  };
}

function authParams(token) {
  return {
    headers: { Authorization: `Bearer ${token}` },
    timeout: '60s',
  };
}

function authJsonParams(token) {
  return {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    timeout: '60s',
  };
}

function jsonParams() {
  return {
    headers: { 'Content-Type': 'application/json' },
    timeout: '60s',
  };
}
