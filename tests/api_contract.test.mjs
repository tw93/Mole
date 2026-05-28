import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const testDir = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(testDir, '..');
const roomy = path.join(projectRoot, 'roomy');
const contracts = JSON.parse(readFileSync(path.join(testDir, 'fixtures', 'api', 'contracts.json'), 'utf8'));

function assertContract(value, contractName, group = 'responses') {
  const contract = contracts[group][contractName];
  assert.ok(contract, `missing API contract fixture: ${group}.${contractName}`);

  for (const [key, rawExpected] of Object.entries(contract)) {
    const optional = rawExpected.endsWith?.('?') ?? false;
    const expected = optional ? rawExpected.slice(0, -1) : rawExpected;

    if (!(key in value)) {
      assert.ok(optional, `expected ${contractName}.${key}`);
      continue;
    }

    if (expected === 'array') {
      assert.ok(Array.isArray(value[key]), `expected ${contractName}.${key} to be array`);
    } else if (expected === 'object') {
      assert.equal(typeof value[key], 'object', `expected ${contractName}.${key} to be object`);
      assert.notEqual(value[key], null, `expected ${contractName}.${key} to be non-null`);
      assert.equal(Array.isArray(value[key]), false, `expected ${contractName}.${key} to be object`);
    } else if (['boolean', 'number', 'string'].includes(expected)) {
      assert.equal(typeof value[key], expected, `expected ${contractName}.${key} to be ${expected}`);
    } else {
      assert.equal(value[key], expected, `expected ${contractName}.${key} to equal ${expected}`);
    }
  }
}

function withHome(fn) {
  const rawHome = mkdtempSync(path.join(os.tmpdir(), 'roomy-api-home-'));
  const home = realpathSync(rawHome);
  mkdirSync(path.join(home, '.config', 'roomy'), { recursive: true });
  mkdirSync(path.join(home, 'Downloads'), { recursive: true });
  mkdirSync(path.join(home, 'Desktop'), { recursive: true });
  try {
    return fn(home);
  } finally {
    rmSync(rawHome, { recursive: true, force: true });
  }
}

function runMo(args, { home, env = {}, allowFailure = false, timeout = 120_000 } = {}) {
  const result = spawnSync(roomy, args, {
    cwd: projectRoot,
    env: {
      ...process.env,
      HOME: home,
      ROOMY_TEST_NO_AUTH: '1',
      TERM: 'dumb',
      ...env,
    },
    encoding: 'utf8',
    timeout,
  });

  if (result.error) {
    throw result.error;
  }

  if (!allowFailure && result.status !== 0) {
    assert.fail(
      `roomy ${args.join(' ')} exited ${result.status}\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`,
    );
  }

  return result;
}

function parseJSON(result) {
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return JSON.parse(result.stdout);
}

function parseEvents(result) {
  const lines = result.stdout.split('\n').filter((line) => line.trim().length > 0);
  assert.ok(lines.length > 0, `expected NDJSON events, got stdout:\n${result.stdout}`);
  return lines.map((line) => JSON.parse(line));
}

function parseError(result) {
  assert.notEqual(result.status, 0, result.stdout || result.stderr);
  return JSON.parse(result.stderr);
}

function writeExecutable(file, content) {
  writeFileSync(file, content);
  chmodSync(file, 0o755);
}

function writePlan(home, name, plan) {
  const file = path.join(home, name);
  writeFileSync(file, `${JSON.stringify(plan)}\n`);
  return file;
}

function diskUsageBytes(target) {
  const result = spawnSync('/usr/bin/du', ['-skP', target], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  const sizeKB = Number.parseInt(result.stdout.trim().split(/\s+/)[0], 10);
  assert.ok(Number.isInteger(sizeKB), `expected du size for ${target}, got ${result.stdout}`);
  return sizeKB * 1024;
}

test('status returns delegated system JSON', () => withHome((home) => {
  const binDir = path.join(home, 'bin');
  mkdirSync(binDir, { recursive: true });
  const statusBin = path.join(binDir, 'status-go');
  writeExecutable(statusBin, `#!/usr/bin/env bash
[[ "$1" == "--json" ]] || exit 2
printf '%s\\n' '{"host":"api-test","health_score":91,"cpu":{"usage":4,"logical_cpu":8},"memory":{"used":1,"total":2,"used_percent":50},"disks":[],"network":[],"top_processes":[],"process_alerts":[]}'
`);

  const data = parseJSON(runMo(['api', 'status'], {
    home,
    env: { ROOMY_TEST_STATUS_BIN: statusBin },
  }));

  assertContract(data, 'status');
  assert.equal(data.host, 'api-test');
  assert.equal(data.health_score, 91);
}));

test('storage scan delegates path to analyzer JSON', () => withHome((home) => {
  const binDir = path.join(home, 'bin');
  mkdirSync(binDir, { recursive: true });
  const analyzeBin = path.join(binDir, 'analyze-go');
  writeExecutable(analyzeBin, `#!/usr/bin/env bash
[[ "$1" == "--json" ]] || exit 2
printf '{"path":"%s","overview":false,"entries":[],"large_files":[],"total_size":0,"total_files":0}\\n' "$2"
`);

  const data = parseJSON(runMo(['api', 'storage', 'scan', '--path', home], {
    home,
    env: { ROOMY_TEST_ANALYZE_BIN: analyzeBin },
  }));

  assertContract(data, 'storage_scan');
  assert.equal(data.path, home);
  assert.deepEqual(data.large_files, []);
}));

test('apps list returns app inventory JSON', () => withHome((home) => {
  const weirdApp = path.join(home, 'Applications', 'Line\nPath.app');
  mkdirSync(path.join(weirdApp, 'Contents'), { recursive: true });
  writeFileSync(path.join(weirdApp, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.line-path</string>
  <key>CFBundleDisplayName</key>
  <string>Display
Name</string>
</dict>
</plist>
`);
  const bellAppName = 'Bell\u0007App';
  const bellApp = path.join(home, 'Applications', `${bellAppName}.app`);
  mkdirSync(bellApp, { recursive: true });

  const data = parseJSON(runMo(['api', 'apps', 'list', '--json'], { home }));

  assertContract(data, 'apps');
  assert.equal(data.schema_version, 1);
  assert.ok(Array.isArray(data.apps));
  data.apps.forEach((item) => assertContract(item, 'app', 'objects'));
  const app = data.apps.find((item) => item.bundle_id === 'com.example.line-path');
  assert.ok(app);
  assert.equal(app.name, 'Display\nName');
  assert.equal(app.uninstall_name, 'Display\nName');
  assert.equal(app.path, weirdApp);
  assert.equal(app.uninstall_supported, false);
  assert.match(app.uninstall_reason, /control characters/);
  const bellAppEntry = data.apps.find((item) => item.path === bellApp);
  assert.ok(bellAppEntry);
  assert.equal(bellAppEntry.name, bellAppName);
  assert.equal(bellAppEntry.uninstall_supported, false);
  assert.match(bellAppEntry.uninstall_reason, /control characters/);
}));

test('apps list keeps case-sensitive base64 inventory records distinct', () => {
  const suffixes = 'abcdefghijklmnopqrstuvwxyz'.split('');
  const home = suffixes.map((suffix) => `/tmp/rf-roomy-api-contract-${suffix}`).find((candidate) => !existsSync(candidate));
  assert.ok(home, 'expected an unused short temp home path');
  const applicationsDir = path.join(home, 'Applications');
  const appNames = ['AAG', 'AAa'];

  try {
    for (const appName of appNames) {
      mkdirSync(path.join(applicationsDir, `${appName}.app`), { recursive: true });
    }

    const data = parseJSON(runMo(['api', 'apps', 'list', '--json'], { home }));
    data.apps.forEach((item) => assertContract(item, 'app', 'objects'));
    for (const appName of appNames) {
      assert.ok(
        data.apps.some((item) => item.name === appName && item.path === path.join(applicationsDir, `${appName}.app`)),
        `expected base64 fold collision app to survive inventory sort: ${appName}`,
      );
    }
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});

test('apps list full inventory returns app row contract', () => withHome((home) => {
  const applicationsDir = path.join(home, 'Applications');
  const appPath = path.join(applicationsDir, 'Full Inventory.app');
  mkdirSync(path.join(appPath, 'Contents'), { recursive: true });
  writeFileSync(path.join(appPath, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.full-inventory</string>
  <key>CFBundleDisplayName</key>
  <string>Full Inventory</string>
</dict>
</plist>
`);
  const binDir = path.join(home, 'bin');
  mkdirSync(binDir, { recursive: true });
  writeExecutable(path.join(binDir, 'pkgutil'), '#!/usr/bin/env bash\nexit 1\n');
  writeExecutable(path.join(binDir, 'mdls'), '#!/usr/bin/env bash\nprintf "%s\\n" "(null)"\n');

  const data = parseJSON(runMo(['api', 'apps', 'list', '--json'], {
    home,
    env: {
      PATH: `${binDir}:${process.env.PATH}`,
      ROOMY_API_FULL_APP_INVENTORY: '1',
      ROOMY_TEST_UNINSTALL_APP_DIRS: applicationsDir,
    },
  }));

  assertContract(data, 'apps');
  data.apps.forEach((item) => assertContract(item, 'app', 'objects'));
  assert.equal(data.apps.length, 1);
  assert.deepEqual(
    {
      name: data.apps[0].name,
      bundle_id: data.apps[0].bundle_id,
      source: data.apps[0].source,
      uninstall_name: data.apps[0].uninstall_name,
      path: data.apps[0].path,
      uninstall_supported: data.apps[0].uninstall_supported,
      uninstall_reason: data.apps[0].uninstall_reason,
    },
    {
      name: 'Full Inventory',
      bundle_id: 'com.example.full-inventory',
      source: 'App',
      uninstall_name: 'Full Inventory',
      path: appPath,
      uninstall_supported: true,
      uninstall_reason: '',
    },
  );
}));

test('apps list full inventory distinguishes empty inventory from scanner failure', () => withHome((home) => {
  const emptyDir = path.join(home, 'Empty Applications');
  mkdirSync(emptyDir, { recursive: true });
  const emptyData = parseJSON(runMo(['api', 'apps', 'list', '--json'], {
    home,
    env: {
      ROOMY_API_FULL_APP_INVENTORY: '1',
      ROOMY_TEST_UNINSTALL_APP_DIRS: emptyDir,
    },
  }));
  assertContract(emptyData, 'apps');
  assert.deepEqual(emptyData.apps, []);

  const applicationsDir = path.join(home, 'Applications');
  const appPath = path.join(applicationsDir, 'Broken Scan.app');
  mkdirSync(path.join(appPath, 'Contents'), { recursive: true });
  writeFileSync(path.join(appPath, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.example.broken-scan</string>
</dict>
</plist>
`);
  const binDir = path.join(home, 'broken-bin');
  mkdirSync(binDir, { recursive: true });
  writeExecutable(path.join(binDir, 'sort'), '#!/usr/bin/env bash\nprintf "%s\\n" "sort exploded" >&2\nexit 2\n');

  const failure = runMo(['api', 'apps', 'list', '--json'], {
    home,
    allowFailure: true,
    env: {
      PATH: `${binDir}:${process.env.PATH}`,
      ROOMY_API_FULL_APP_INVENTORY: '1',
      ROOMY_TEST_UNINSTALL_APP_DIRS: applicationsDir,
    },
  });
  const error = parseError(failure);
  assert.equal(error.error.code, 'apps_inventory_failed');
  assert.match(error.error.message, /Application inventory failed/);
  assert.match(error.error.message, /sort exploded/);
}));

test('apps list full inventory rejects malformed upstream JSON', () => withHome((home) => {
  const result = runMo(['api', 'apps', 'list', '--json'], {
    home,
    allowFailure: true,
    env: {
      ROOMY_API_FULL_APP_INVENTORY: '1',
      ROOMY_TEST_API_FULL_APPS_JSON: '[{"name":"Broken",]',
    },
  });

  const error = parseError(result);
  assert.equal(error.error.code, 'invalid_apps_json');
  assert.match(error.error.message, /valid JSON array/);
}));

test('storage execute dry-runs Trash actions and refuses escaped targets', () => withHome((home) => {
  const scanRoot = path.join(home, 'Downloads');
  const target = path.join(scanRoot, 'Large, [quoted] "path" \\ #@ file.bin');
  const directoryTarget = path.join(scanRoot, 'Directory Target');
  const outside = path.join(home, 'Desktop', 'Outside, [quoted] "path" \\ #@ file.bin');
  mkdirSync(directoryTarget, { recursive: true });
  writeFileSync(target, 'large-file');
  writeFileSync(path.join(directoryTarget, 'first.bin'), 'first');
  writeFileSync(path.join(directoryTarget, 'second.bin'), 'second');
  writeFileSync(outside, 'outside');
  const expectedDirectoryBytes = diskUsageBytes(directoryTarget);

  const okPlan = writePlan(home, 'storage-ok.json', {
    confirmed: true,
    dry_run: true,
    operation: 'trash',
    scan_path: scanRoot,
    targets: [target, directoryTarget],
  });
  const okEvents = parseEvents(runMo(['api', 'storage', 'execute', '--plan', okPlan], { home }));
  okEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(okEvents[0].event, 'started');
  assert.equal(okEvents.at(-1).event, 'completed');
  const progressEvents = okEvents.filter((event) => event.message === 'Would move item to Trash');
  const fileProgress = progressEvents.find((event) => event.path === target);
  const directoryProgress = progressEvents.find((event) => event.path === directoryTarget);
  assert.ok(fileProgress);
  assert.ok(directoryProgress);
  assert.equal(fileProgress.bytes, 10);
  assert.equal(directoryProgress.bytes, expectedDirectoryBytes);
  assert.equal(okEvents.at(-1).operation, 'trash');
  assert.equal(okEvents.at(-1).item_count, 2);
  assert.equal(okEvents.at(-1).bytes, 10 + expectedDirectoryBytes);
  const journal = readFileSync(path.join(home, 'Library', 'Logs', 'roomy', 'operation_journal.jsonl'), 'utf8')
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  assert.ok(journal.some((record) =>
    record.record_type === 'event' &&
    record.payload?.domain === 'storage' &&
    record.payload?.event === 'completed' &&
    record.payload?.item_count === 2
  ));

  const newlineTarget = path.join(scanRoot, 'Line\nBreak.bin');
  const trailingNewlineTarget = path.join(scanRoot, 'Trailing newline\n');
  writeFileSync(newlineTarget, 'newline-target');
  writeFileSync(trailingNewlineTarget, 'trailing-newline-target');
  const revealPlan = writePlan(home, 'storage-newline-target.json', {
    confirmed: true,
    dry_run: true,
    operation: 'reveal',
    scan_path: scanRoot,
    targets: [newlineTarget, trailingNewlineTarget],
  });
  const revealEvents = parseEvents(runMo(['api', 'storage', 'execute', '--plan', revealPlan], { home }));
  revealEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(revealEvents.at(-1).event, 'completed');
  const revealProgressPaths = revealEvents
    .filter((event) => event.message === 'Would reveal in Finder')
    .map((event) => event.path);
  assert.deepEqual(revealProgressPaths, [newlineTarget, trailingNewlineTarget]);

  const openBinDir = path.join(home, 'bin');
  const openLog = path.join(home, 'open-argv.bin');
  mkdirSync(openBinDir, { recursive: true });
  writeExecutable(path.join(openBinDir, 'open'), '#!/usr/bin/env bash\nprintf "%s\\0" "$@" >> "$OPEN_LOG"\n');
  const revealLivePlan = writePlan(home, 'storage-live-reveal-newline-target.json', {
    confirmed: true,
    operation: 'reveal',
    scan_path: scanRoot,
    targets: [newlineTarget],
  });
  const liveRevealEvents = parseEvents(runMo(['api', 'storage', 'execute', '--plan', revealLivePlan], {
    home,
    env: { OPEN_LOG: openLog, PATH: `${openBinDir}:${process.env.PATH}` },
  }));
  liveRevealEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(liveRevealEvents.at(-1).event, 'completed');
  const openArgs = readFileSync(openLog, 'utf8').split('\0').filter((value) => value.length > 0);
  assert.deepEqual(openArgs, ['-R', newlineTarget]);

  const newlineTrashPlan = writePlan(home, 'storage-newline-trash-target.json', {
    confirmed: true,
    dry_run: true,
    operation: 'trash',
    scan_path: scanRoot,
    targets: [newlineTarget],
  });
  const newlineTrashRefused = runMo(['api', 'storage', 'execute', '--plan', newlineTrashPlan], {
    home,
    allowFailure: true,
  });
  assert.notEqual(newlineTrashRefused.status, 0);
  const newlineTrashEvents = parseEvents(newlineTrashRefused);
  newlineTrashEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(newlineTrashEvents.length, 2);
  assert.equal(newlineTrashEvents.at(-1).event, 'failed');
  assert.match(newlineTrashEvents.at(-1).message, /targets.*control characters/);

  const newlineScanRoot = path.join(home, 'Scan Root\n');
  const newlineScanTarget = path.join(newlineScanRoot, 'Item.bin');
  mkdirSync(newlineScanRoot, { recursive: true });
  writeFileSync(newlineScanTarget, 'newline-scan-root');
  const newlineScanPlan = writePlan(home, 'storage-newline-scan-root.json', {
    confirmed: true,
    dry_run: true,
    operation: 'reveal',
    scan_path: newlineScanRoot,
    targets: [newlineScanTarget],
  });
  const newlineScanEvents = parseEvents(runMo(['api', 'storage', 'execute', '--plan', newlineScanPlan], { home }));
  newlineScanEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(newlineScanEvents.at(-1).event, 'completed');
  assert.equal(
    newlineScanEvents.find((event) => event.message === 'Would reveal in Finder')?.path,
    newlineScanTarget,
  );

  const refusedPlan = writePlan(home, 'storage-refused.json', {
    confirmed: true,
    dry_run: true,
    operation: 'trash',
    scan_path: scanRoot,
    targets: [outside],
  });
  const refused = runMo(['api', 'storage', 'execute', '--plan', refusedPlan], { home, allowFailure: true });
  assert.notEqual(refused.status, 0);
  const refusedEvents = parseEvents(refused);
  refusedEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(refusedEvents.at(-1).event, 'failed');
  const skipped = refusedEvents.find((event) => event.event === 'skipped');
  assert.ok(skipped);
  assert.equal(skipped.path, outside);
  assert.equal(skipped.scan_path, scanRoot);

  const outsideDir = path.join(home, 'Desktop', 'Outside Dir');
  const escapedLink = path.join(scanRoot, 'Outside Link');
  mkdirSync(outsideDir, { recursive: true });
  writeFileSync(path.join(outsideDir, 'keep.bin'), 'keep');
  symlinkSync(outsideDir, escapedLink, 'dir');
  const linkPlan = writePlan(home, 'storage-symlink-refused.json', {
    confirmed: true,
    dry_run: true,
    operation: 'trash',
    scan_path: scanRoot,
    targets: [escapedLink],
  });
  const linkRefused = runMo(['api', 'storage', 'execute', '--plan', linkPlan], { home, allowFailure: true });
  assert.notEqual(linkRefused.status, 0);
  const linkEvents = parseEvents(linkRefused);
  linkEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(linkEvents.at(-1).event, 'failed');
  const linkSkipped = linkEvents.find((event) => event.event === 'skipped');
  assert.ok(linkSkipped);
  assert.equal(linkSkipped.path, outsideDir);
  assert.equal(linkSkipped.scan_path, scanRoot);
  assert.equal(lstatSync(escapedLink).isSymbolicLink(), true);
  assert.equal(readFileSync(path.join(outsideDir, 'keep.bin'), 'utf8'), 'keep');
}));

test('API error JSON escapes messages with quotes and backslashes', () => withHome((home) => {
  const result = runMo(['api', 'storage', 'scan', '--path', home, '--bad "quote" \\ path'], {
    home,
    allowFailure: true,
  });
  const data = parseError(result);
  assertContract(data, 'base', 'errors');
  assert.equal(data.error.code, 'usage');
  assert.equal(data.error.message, 'Unknown storage scan option: --bad "quote" \\ path');
}));

test('execute plan schemas reject malformed and partial plans before actions start', () => withHome((home) => {
  const badJSON = path.join(home, 'bad.json');
  writeFileSync(badJSON, '{"confirmed": true');
  const badJSONEvents = parseEvents(runMo(['api', 'clean', 'execute', '--plan', badJSON], {
    home,
    allowFailure: true,
  }));
  assert.equal(badJSONEvents.at(-1).event, 'failed');
  assert.equal(badJSONEvents.at(-1).message, 'Plan JSON is invalid');

  const wrongTargets = writePlan(home, 'wrong-targets.json', {
    confirmed: true,
    dry_run: true,
    targets: path.join(home, 'Downloads', 'Test.pkg'),
  });
  const installerEvents = parseEvents(runMo(['api', 'installer', 'execute', '--plan', wrongTargets], {
    home,
    allowFailure: true,
  }));
  assert.equal(installerEvents.at(-1).event, 'failed');
  assert.match(installerEvents.at(-1).message, /targets.*array/);

  const controlTargets = writePlan(home, 'control-targets.json', {
    confirmed: true,
    dry_run: true,
    targets: [path.join(home, 'Downloads', 'Line\nInstaller.dmg')],
  });
  const controlInstallerEvents = parseEvents(runMo(['api', 'installer', 'execute', '--plan', controlTargets], {
    home,
    allowFailure: true,
  }));
  assert.equal(controlInstallerEvents.at(-1).event, 'failed');
  assert.match(controlInstallerEvents.at(-1).message, /targets.*control characters/);

  const invalidStorageOperation = writePlan(home, 'invalid-storage-operation.json', {
    confirmed: true,
    dry_run: true,
    operation: 'delete',
    scan_path: home,
    targets: [path.join(home, 'Downloads', 'Test.bin')],
  });
  const invalidStorageOperationEvents = parseEvents(runMo(['api', 'storage', 'execute', '--plan', invalidStorageOperation], {
    home,
    allowFailure: true,
  }));
  assert.equal(invalidStorageOperationEvents.at(-1).event, 'failed');
  assert.match(invalidStorageOperationEvents.at(-1).message, /operation.*reveal, open, or trash/);

  const wrongUpdate = writePlan(home, 'wrong-update.json', {
    confirmed: true,
    dry_run: true,
    force: 'yes',
  });
  const updateEvents = parseEvents(runMo(['api', 'update', 'execute', '--plan', wrongUpdate], {
    home,
    allowFailure: true,
  }));
  assert.equal(updateEvents.at(-1).event, 'failed');
  assert.match(updateEvents.at(-1).message, /force.*bool/);

  const emptyUninstall = writePlan(home, 'empty-uninstall.json', {
    confirmed: true,
    dry_run: true,
    uninstall_names: [],
  });
  const uninstallEvents = parseEvents(runMo(['api', 'uninstall', 'execute', '--plan', emptyUninstall], {
    home,
    allowFailure: true,
  }));
  assert.equal(uninstallEvents.at(-1).event, 'failed');
  assert.match(uninstallEvents.at(-1).message, /uninstall_names.*at least one/);

  const controlUninstall = writePlan(home, 'control-uninstall.json', {
    confirmed: true,
    dry_run: true,
    uninstall_names: ['Bad\nApp'],
  });
  const controlUninstallEvents = parseEvents(runMo(['api', 'uninstall', 'execute', '--plan', controlUninstall], {
    home,
    allowFailure: true,
  }));
  assert.equal(controlUninstallEvents.at(-1).event, 'failed');
  assert.match(controlUninstallEvents.at(-1).message, /uninstall_names.*control characters/);

  const controlPurgePaths = writePlan(home, 'control-purge-paths.json', {
    confirmed: true,
    paths: [path.join(home, 'Projects\nBad')],
  });
  const controlPurgePathEvents = parseEvents(runMo(['api', 'purge', 'paths', 'update', '--plan', controlPurgePaths], {
    home,
    allowFailure: true,
  }));
  assert.equal(controlPurgePathEvents.at(-1).event, 'failed');
  assert.match(controlPurgePathEvents.at(-1).message, /paths.*control characters/);
}));

test('clean preview returns structured cleanup JSON including external volumes', () => withHome((home) => {
  mkdirSync(path.join(home, 'Library', 'Caches', 'TestApp'), { recursive: true });
  writeFileSync(path.join(home, 'Library', 'Caches', 'TestApp', 'file.tmp'), 'cache');

  const clean = parseJSON(runMo(['api', 'clean', 'preview', '--json'], {
    home,
    env: { ROOMY_TEST_MODE: '1' },
  }));
  assertContract(clean, 'cleanup_preview');
  assert.equal(clean.command, 'clean.preview');
  assert.equal(clean.dry_run, true);
  assert.ok(Array.isArray(clean.categories));
  assert.ok('estimated_bytes' in clean);

  const volumesRoot = path.join(home, 'Volumes');
  const volume = path.join(volumesRoot, 'TestVolume\n');
  mkdirSync(path.join(volume, '.Trashes'), { recursive: true });
  mkdirSync(path.join(volume, 'Folder'), { recursive: true });
  writeFileSync(path.join(volume, '.Trashes', 'item'), 'trash');
  writeFileSync(path.join(volume, 'Folder', '._file'), 'metadata');

  const external = parseJSON(runMo(['api', 'clean', 'preview', '--json', '--external', volume], {
    home,
    env: { ROOMY_EXTERNAL_VOLUMES_ROOT: volumesRoot },
  }));
  assertContract(external, 'cleanup_preview');
  assert.equal(external.command, 'clean.preview');
  assert.ok(external.categories.some((category) => category.section === 'External volume'));
}));

test('optimize, installer, purge, whitelist, and purge paths previews return contracts', () => withHome((home) => {
  const optimize = parseJSON(runMo(['api', 'optimize', 'preview'], { home }));
  assertContract(optimize, 'optimize_preview');
  assert.ok(Array.isArray(optimize.optimizations));

  const installerTarget = path.join(home, 'Downloads', 'Test.DMG');
  const newlineInstallerTarget = path.join(home, 'Downloads', 'Line\nInstaller.DMG');
  writeFileSync(installerTarget, 'dmg');
  writeFileSync(newlineInstallerTarget, 'newline-dmg');
  const installer = parseJSON(runMo(['api', 'installer', 'preview', '--json'], { home }));
  assertContract(installer, 'installer_preview');
  assert.equal(installer.command, 'installer.preview');
  assert.ok(installer.items.some((item) => item.path.endsWith('Test.DMG')));
  assert.equal(installer.items.some((item) => item.path === newlineInstallerTarget), false);

  const artifact = path.join(home, 'Projects', 'App', 'node_modules');
  mkdirSync(artifact, { recursive: true });
  writeFileSync(path.join(artifact, 'package.txt'), 'module');
  writeFileSync(path.join(home, 'Projects', 'App', 'package.json'), '{}\n');
  const newlineProjectRoot = path.join(home, 'Projects', 'Line\nProject');
  const newlineArtifact = path.join(newlineProjectRoot, 'node_modules');
  mkdirSync(newlineArtifact, { recursive: true });
  writeFileSync(path.join(newlineArtifact, 'package.txt'), 'newline-module');
  writeFileSync(path.join(newlineProjectRoot, 'package.json'), '{}\n');
  const purge = parseJSON(runMo(['api', 'purge', 'preview', '--json'], { home }));
  assertContract(purge, 'purge_preview');
  assert.equal(purge.command, 'purge.preview');
  assert.ok(purge.items.some((item) => item.path.endsWith('node_modules')));
  assert.equal(purge.items.some((item) => item.path === newlineArtifact), false);

  const whitelistBefore = parseJSON(runMo(['api', 'whitelist', 'list', '--mode', 'clean'], { home }));
  assertContract(whitelistBefore, 'whitelist');
  assert.equal(whitelistBefore.mode, 'clean');
  assert.ok(Array.isArray(whitelistBefore.items));

  const whitelistPlan = writePlan(home, 'whitelist-plan.json', {
    confirmed: true,
    patterns: ['~/Library/Caches/KeepMe'],
  });
  const whitelistEvents = parseEvents(runMo(
    ['api', 'whitelist', 'update', '--mode', 'clean', '--plan', whitelistPlan],
    { home },
  ));
  whitelistEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(whitelistEvents.at(-1).event, 'completed');
  const whitelistPath = path.join(home, '.config', 'roomy', 'whitelist');
  const whitelistFileBeforeInvalidUpdate = readFileSync(whitelistPath, 'utf8');

  const invalidWhitelistPlan = writePlan(home, 'whitelist-invalid-plan.json', {
    confirmed: true,
    patterns: ['~/Library/Caches/KeepMe', 'bad\npattern'],
  });
  const invalidWhitelistResult = runMo(
    ['api', 'whitelist', 'update', '--mode', 'clean', '--plan', invalidWhitelistPlan],
    { home, allowFailure: true },
  );
  assert.notEqual(invalidWhitelistResult.status, 0);
  const invalidWhitelistEvents = parseEvents(invalidWhitelistResult);
  invalidWhitelistEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(invalidWhitelistEvents.at(-1).event, 'failed');
  assert.equal(invalidWhitelistEvents.at(-1).domain, 'whitelist');
  assert.match(invalidWhitelistEvents.at(-1).message, /cannot contain control characters/);
  assert.equal(readFileSync(whitelistPath, 'utf8'), whitelistFileBeforeInvalidUpdate);

  const pathsPlan = writePlan(home, 'purge-paths-plan.json', {
    confirmed: true,
    paths: [path.join(home, 'Projects')],
  });
  const pathsEvents = parseEvents(runMo(['api', 'purge', 'paths', 'update', '--plan', pathsPlan], { home }));
  pathsEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(pathsEvents.at(-1).domain, 'purge_paths');

  const purgePaths = parseJSON(runMo(['api', 'purge', 'paths', '--json'], { home }));
  assertContract(purgePaths, 'purge_paths');
  assert.ok(purgePaths.paths.includes(path.join(home, 'Projects')));

  const unsafePathsPlan = writePlan(home, 'purge-paths-unsafe-plan.json', {
    confirmed: true,
    paths: ['/', home, 'relative/project'],
  });
  const unsafePathsResult = runMo(
    ['api', 'purge', 'paths', 'update', '--plan', unsafePathsPlan],
    { home, allowFailure: true },
  );
  assert.notEqual(unsafePathsResult.status, 0);
  const unsafePathsEvents = parseEvents(unsafePathsResult);
  unsafePathsEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assert.equal(unsafePathsEvents.at(-1).event, 'failed');
  assert.equal(unsafePathsEvents.at(-1).domain, 'purge_paths');
  assert.match(unsafePathsEvents.at(-1).message, /Unsafe project scan path/);
}));

test('settings and maintenance endpoints return JSON contracts', () => withHome((home) => {
  const completion = parseJSON(runMo(['api', 'completion', 'status'], {
    home,
    env: { SHELL: '/bin/zsh' },
  }));
  assertContract(completion, 'completion_status');
  assert.equal(completion.shell, 'zsh');
  assert.ok('installed' in completion);

  const launchers = parseJSON(runMo(['api', 'launchers', 'status'], { home }));
  assertContract(launchers, 'launchers_status');
  assert.equal(launchers.schema_version, 1);
  assert.equal(launchers.command_count, 5);
  assert.ok(launchers.commands.some((command) => command.command === 'clean'));

  const touchID = parseJSON(runMo(['api', 'touchid', 'status'], { home }));
  assertContract(touchID, 'touchid_status');
  assert.equal(touchID.schema_version, 1);
  assert.ok('supported' in touchID);

  const update = parseJSON(runMo(['api', 'update', 'status'], { home }));
  assertContract(update, 'maintenance_status');
  assert.equal(update.schema_version, 1);
  assert.ok(update.version);
  assert.ok(update.cli_path.endsWith('/roomy'));
}));

test('purge preview handles large project containers within smoke-test budget', () => withHome((home) => {
  const root = path.join(home, 'Projects');
  for (let index = 0; index < 120; index += 1) {
    const project = path.join(root, `App-${index}`);
    const artifact = path.join(project, 'node_modules');
    mkdirSync(artifact, { recursive: true });
    writeFileSync(path.join(project, 'package.json'), '{}\n');
    writeFileSync(path.join(artifact, 'package.txt'), `module-${index}`);
  }

  const started = Date.now();
  const purge = parseJSON(runMo(['api', 'purge', 'preview', '--json'], { home, timeout: 30_000 }));
  const elapsed = Date.now() - started;

  assertContract(purge, 'purge_preview');
  assert.ok(purge.item_count >= 100, `expected many purge artifacts, got ${purge.item_count}`);
  assert.ok(elapsed < 30_000, `purge preview took ${elapsed}ms`);
}));

test('execute endpoints stream NDJSON safety events', () => withHome((home) => {
  const unconfirmed = writePlan(home, 'unconfirmed.json', { confirmed: false, dry_run: true });
  const refused = runMo(['api', 'clean', 'execute', '--plan', unconfirmed], { home, allowFailure: true });
  assert.notEqual(refused.status, 0);
  const refusedEvents = parseEvents(refused);
  refusedEvents.forEach((event) => assertContract(event, 'base', 'events'));
  assertContract(refusedEvents.at(-1), 'failure', 'events');

  const launcherPlan = writePlan(home, 'launchers.json', { confirmed: true, dry_run: true });
  assert.equal(
    parseEvents(runMo(['api', 'launchers', 'execute', '--plan', launcherPlan], { home })).at(-1).event,
    'completed',
  );

  const completionPlan = writePlan(home, 'completion.json', { confirmed: true, dry_run: true });
  assert.equal(
    parseEvents(runMo(['api', 'completion', 'execute', '--plan', completionPlan], {
      home,
      env: { SHELL: '/bin/zsh', PATH: `${projectRoot}:${process.env.PATH ?? ''}` },
    })).at(-1).event,
    'completed',
  );

  const touchIDPlan = writePlan(home, 'touchid.json', { confirmed: true, dry_run: true });
  assert.equal(
    parseEvents(runMo(['api', 'touchid', 'execute', '--action', 'enable', '--plan', touchIDPlan], { home })).at(-1).event,
    'completed',
  );

  const updatePlan = writePlan(home, 'update.json', { confirmed: true, dry_run: true, force: true });
  assert.equal(
    parseEvents(runMo(['api', 'update', 'execute', '--plan', updatePlan], { home })).at(-1).event,
    'completed',
  );

  mkdirSync(path.join(home, '.local', 'bin'), { recursive: true });
  writeExecutable(path.join(home, '.local', 'bin', 'roomy'), '#!/usr/bin/env bash\n');
  const removePlan = writePlan(home, 'remove.json', { confirmed: true, dry_run: true });
  assert.equal(
    parseEvents(runMo(['api', 'remove', 'execute', '--plan', removePlan], {
      home,
      env: { ROOMY_TEST_MODE: '1' },
    })).at(-1).event,
    'completed',
  );

  const installerTarget = path.join(home, 'Downloads', 'Test.PKG');
  writeFileSync(installerTarget, 'pkg');
  const installerPlan = writePlan(home, 'installer.json', {
    confirmed: true,
    dry_run: true,
    targets: [installerTarget],
  });
  assert.equal(
    parseEvents(runMo(['api', 'installer', 'execute', '--plan', installerPlan], { home })).at(-1).event,
    'completed',
  );

  const brokenInstaller = path.join(home, 'Downloads', 'Old.dmg');
  symlinkSync(path.join(home, 'Downloads', 'Missing.dmg'), brokenInstaller);
  const brokenInstallerPlan = writePlan(home, 'installer-broken-link.json', {
    confirmed: true,
    targets: [brokenInstaller],
  });
  const brokenInstallerEvents = parseEvents(runMo(['api', 'installer', 'execute', '--plan', brokenInstallerPlan], { home }));
  assert.equal(brokenInstallerEvents.at(-1).event, 'completed');
  assert.equal(brokenInstallerEvents.at(-1).removed_count, 1);
  assert.throws(() => lstatSync(brokenInstaller), /ENOENT/);

  const nonInstallerZip = path.join(home, 'Downloads', 'Archive.ZIP');
  writeFileSync(nonInstallerZip, 'not a zip with installer payload');
  const nonInstallerZipPlan = writePlan(home, 'installer-non-installer-zip.json', {
    confirmed: true,
    targets: [nonInstallerZip],
  });
  const nonInstallerZipEvents = parseEvents(runMo(['api', 'installer', 'execute', '--plan', nonInstallerZipPlan], {
    home,
    allowFailure: true,
  }));
  assert.equal(nonInstallerZipEvents.at(-1).event, 'failed');
  assert.ok(nonInstallerZipEvents.some((event) => event.message === 'ZIP does not contain installer payload'));
  assert.ok(lstatSync(nonInstallerZip).isFile());

  const newlineProject = path.join(home, 'Projects', 'Line\nExecute');
  const newlinePurgeTarget = path.join(newlineProject, 'node_modules');
  mkdirSync(newlinePurgeTarget, { recursive: true });
  writeFileSync(path.join(newlineProject, 'package.json'), '{}\n');
  writeFileSync(path.join(newlinePurgeTarget, 'package.txt'), 'module');
  const newlinePurgePlan = writePlan(home, 'purge-newline-target.json', {
    confirmed: true,
    dry_run: true,
    targets: [newlinePurgeTarget],
  });
  const newlinePurgeRefused = runMo(['api', 'purge', 'execute', '--plan', newlinePurgePlan], {
    home,
    allowFailure: true,
  });
  assert.notEqual(newlinePurgeRefused.status, 0);
  const newlinePurgeEvents = parseEvents(newlinePurgeRefused);
  assert.equal(newlinePurgeEvents.at(-1).event, 'failed');
  assert.match(newlinePurgeEvents.at(-1).message, /targets.*control characters/);
  assert.equal(newlinePurgeEvents.some((event) => event.message === 'Would remove project artifact'), false);

  const project = path.join(home, 'Projects', 'ExecuteApp');
  const protectedPurgeTarget = path.join(project, 'node_modules');
  mkdirSync(project, { recursive: true });
  writeFileSync(path.join(project, 'package.json'), '{}\n');
  symlinkSync('/etc', protectedPurgeTarget, 'dir');
  const purgePlan = writePlan(home, 'purge-protected-link.json', {
    confirmed: true,
    dry_run: true,
    targets: [protectedPurgeTarget],
  });
  const purgeRefused = runMo(['api', 'purge', 'execute', '--plan', purgePlan], { home, allowFailure: true });
  assert.notEqual(purgeRefused.status, 0);
  const purgeEvents = parseEvents(purgeRefused);
  assert.equal(purgeEvents.at(-1).event, 'failed');
  assert.equal(purgeEvents.find((event) => event.event === 'skipped')?.message, 'Path failed deletion validation');
  assert.equal(purgeEvents.some((event) => event.message === 'Would remove project artifact'), false);
  assert.equal(lstatSync(protectedPurgeTarget).isSymbolicLink(), true);

  const volumesRoot = path.join(home, 'Volumes');
  const volume = path.join(volumesRoot, 'TestVolume');
  mkdirSync(path.join(volume, '.Trashes'), { recursive: true });
  writeFileSync(path.join(volume, '.Trashes', 'item'), 'trash');
  const externalCleanPlan = writePlan(home, 'external-clean.json', {
    confirmed: true,
    dry_run: true,
    external_path: volume,
  });
  const externalCleanEvents = parseEvents(runMo(['api', 'clean', 'execute', '--plan', externalCleanPlan], {
    home,
    env: { ROOMY_EXTERNAL_VOLUMES_ROOT: volumesRoot },
  }));
  const externalCleanCompleted = externalCleanEvents.at(-1);
  assert.equal(externalCleanCompleted.event, 'completed');
  assert.equal(externalCleanCompleted.domain, 'clean');
  assert.equal(typeof externalCleanCompleted.bytes, 'number');
  assert.equal(typeof externalCleanCompleted.item_count, 'number');
  assert.equal(typeof externalCleanCompleted.category_count, 'number');
  assert.equal(typeof externalCleanCompleted.free_space, 'string');

  const uninstallPlan = writePlan(home, 'uninstall.json', {
    confirmed: true,
    dry_run: true,
    uninstall_names: ['--permanent'],
  });
  const uninstall = runMo(['api', 'uninstall', 'execute', '--plan', uninstallPlan], {
    home,
    allowFailure: true,
  });
  const uninstallEvents = parseEvents(uninstall);
  assert.equal(uninstallEvents[0].domain, 'uninstall');
  assert.ok(uninstallEvents.some((event) => event.message === 'No matching applications found.'));
  assert.ok(!uninstallEvents.some((event) => /Unknown uninstall option/.test(event.message ?? '')));
}));
