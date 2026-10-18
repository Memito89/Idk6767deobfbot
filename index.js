'use strict';
require('dotenv').config();

const { execFile }               = require('child_process');
const { writeFile, unlink, mkdir, chmod, readFile } = require('fs/promises');
const { existsSync, createWriteStream }              = require('fs');
const path                       = require('path');
const os                         = require('os');
const https                      = require('https');
const AdmZip                     = require('adm-zip');
const { promisify }              = require('util');
const execFileAsync              = promisify(execFile);

const {
  Client, GatewayIntentBits, EmbedBuilder,
  AttachmentBuilder, SlashCommandBuilder, REST, Routes,
} = require('discord.js');

// ─── Config ───────────────────────────────────────────────────────────────────
const TOKEN       = process.env.DISCORD_TOKEN;
const CLIENT_ID   = process.env.CLIENT_ID;
const EXEC_TIMEOUT = 12_000; // 12 s max execution
const MAX_SIZE     = 500_000;

if (!TOKEN || !CLIENT_ID) {
  console.error('❌  Missing DISCORD_TOKEN or CLIENT_ID in .env');
  process.exit(1);
}

// ─── Lune binary management ───────────────────────────────────────────────────
const LOCAL_LUNE = path.join(__dirname, process.platform === 'win32' ? 'lune.exe' : 'lune');
const LUNE_VERSION = '0.8.9';

function luneTarget() {
  const { platform, arch } = process;
  if (platform === 'linux'  && arch === 'x64')   return `lune-${LUNE_VERSION}-x86_64-unknown-linux-gnu`;
  if (platform === 'darwin' && arch === 'x64')   return `lune-${LUNE_VERSION}-x86_64-apple-darwin`;
  if (platform === 'darwin' && arch === 'arm64') return `lune-${LUNE_VERSION}-aarch64-apple-darwin`;
  if (platform === 'win32'  && arch === 'x64')   return `lune-${LUNE_VERSION}-x86_64-pc-windows-msvc`;
  return null;
}

async function downloadFile(url, dest) {
  await mkdir(path.dirname(dest), { recursive: true });
  return new Promise((resolve, reject) => {
    const follow = (u) => {
      https.get(u, (res) => {
        if (res.statusCode === 301 || res.statusCode === 302) {
          return follow(res.headers.location);
        }
        if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode}`));
        const ws = createWriteStream(dest);
        res.pipe(ws);
        ws.on('finish', resolve);
        ws.on('error', reject);
      }).on('error', reject);
    };
    follow(url);
  });
}

async function ensureLune() {
  // 1. Already in PATH?
  try {
    await execFileAsync('lune', ['--version'], { timeout: 3000 });
    return 'lune';
  } catch {}

  // 2. Local binary cached?
  if (existsSync(LOCAL_LUNE)) return LOCAL_LUNE;

  // 3. Auto-download from GitHub releases
  const target = luneTarget();
  if (!target) throw new Error('Unsupported platform. Install lune manually: https://github.com/lune-org/lune/releases');

  const isWin = process.platform === 'win32';
  const ext   = isWin ? '.zip' : '.zip';
  const url   = `https://github.com/lune-org/lune/releases/download/v${LUNE_VERSION}/${target}${ext}`;
  const zipDest = LOCAL_LUNE + '.zip';

  console.log(`⬇️  Downloading lune v${LUNE_VERSION}...`);
  await downloadFile(url, zipDest);

  // Extract purely in Node — no system unzip needed (works on Railway)
  const zip   = new AdmZip(zipDest);
  const entry = zip.getEntries().find(e =>
    !e.isDirectory && (e.entryName === 'lune' || e.entryName === 'lune.exe' ||
                       e.entryName.endsWith('/lune') || e.entryName.endsWith('/lune.exe')));
  if (!entry) throw new Error('lune binary not found inside zip');
  zip.extractEntryTo(entry, __dirname, /*maintainPath*/ false, /*overwrite*/ true);
  if (process.platform !== 'win32') await chmod(LOCAL_LUNE, 0o755);
  await unlink(zipDest).catch(() => {});

  console.log('✅  lune ready.');
  return LOCAL_LUNE;
}

// ─── Deobfuscation passes ─────────────────────────────────────────────────────
function deobfuscate(src) {
  let out = src;

  // \x41 → A
  out = out.replace(/\\x([0-9a-fA-F]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16)));

  // \65 → A  (decimal escapes)
  out = out.replace(/\\(\d{1,3})/g, (_, d) => {
    const n = parseInt(d, 10);
    return n <= 255 ? String.fromCharCode(n) : `\\${d}`;
  });

  // string.char(72,101,108) → "Hel"
  out = out.replace(/string\.char\(([0-9,\s]+)\)/g, (m, args) => {
    try {
      const chars = args.split(',').map(s => parseInt(s.trim(), 10));
      if (chars.some(isNaN)) return m;
      return JSON.stringify(chars.map(c => String.fromCharCode(c)).join(''));
    } catch { return m; }
  });

  // bit32.bxor single char fold
  out = out.replace(/string\.char\s*\(\s*bit32\.bxor\s*\((\d+)\s*,\s*(\d+)\s*\)\s*\)/g,
    (_, a, b) => JSON.stringify(String.fromCharCode(parseInt(a) ^ parseInt(b))));

  // "a".."b" → "ab"  (multiple passes)
  let prev;
  do {
    prev = out;
    out = out.replace(/"([^"\\]*)"\s*\.\.\s*"([^"\\]*)"/g, (_, a, b) => `"${a}${b}"`);
  } while (out !== prev);

  // String table inlining
  const tableRe = /local\s+(\w+)\s*=\s*\{((?:\s*(?:"[^"]*"|'[^']*')\s*,?\s*){3,})\}/g;
  const tables = {};
  out.replace(tableRe, (_, name, body) => {
    const entries = [];
    const sp = /"([^"]*)"|'([^']*)'/g;
    let m;
    while ((m = sp.exec(body)) !== null) entries.push(m[1] ?? m[2]);
    if (entries.length) tables[name] = entries;
  });
  for (const [name, entries] of Object.entries(tables)) {
    const re = new RegExp(`\\b${name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}\\s*\\[\\s*(\\d+)\\s*\\]`, 'g');
    out = out.replace(re, (_, idx) => {
      const v = entries[parseInt(idx) - 1];
      return v != null ? JSON.stringify(v) : _;
    });
  }

  // Annotate base64 blobs
  out = out.replace(/["']([A-Za-z0-9+/]{60,}={0,2})["']/g, (match, b64) => {
    try {
      const d = Buffer.from(b64, 'base64').toString('utf8');
      if (/local|function|return|require|game\.|workspace/.test(d))
        return `${match} --[[B64≈ ${d.replace(/\n/g,' ').slice(0,100)}...]]`;
    } catch {}
    return match;
  });

  // Strip comments after decode passes
  out = out.replace(/--\[=*\[[\s\S]*?\]=*\]/g, '');
  out = out.replace(/--[^\n]*/g, '');

  // Rename _0x / hex-like identifiers
  const hexRe = /_(?:0x)?[0-9a-fA-F]{4,}/g;
  const nameMap = new Map();
  const prefixes = ['fn','tbl','val','str','num','obj','cb','mod'];
  let c = 0;
  out = out.replace(hexRe, m => {
    if (!nameMap.has(m)) nameMap.set(m, `${prefixes[c % prefixes.length]}_${(c++).toString(16).padStart(3,'0')}`);
    return nameMap.get(m);
  });

  return out.replace(/\n{3,}/g, '\n\n').trim();
}

function detectObfuscator(src) {
  if (/--\s*IronBrew/i.test(src) || /local\s+VM\s*=/.test(src)) return 'IronBrew 2';
  if (/--\s*Moonsec/i.test(src))   return 'Moonsec';
  if (/--\s*Luraph/i.test(src))    return 'Luraph';
  if (/--\s*PSU/i.test(src))       return 'PSU';
  if (/AztupBrew/i.test(src))      return 'AztupBrew';
  if (/string\.dump/.test(src))    return 'Bytecode VM';
  const shortRatio = (src.match(/\b[a-zA-Z_]\w{0,2}\b/g) || []).length
                   / ((src.match(/\b[a-zA-Z_]\w*\b/g) || []).length || 1);
  if (shortRatio > 0.78 && src.length > 300) return 'Unknown (identifier obfuscation)';
  return null;
}

// ─── Parse sandbox output ─────────────────────────────────────────────────────
const BEHAVIOR_MAP = {
  HTTP_GET:            { label: '🌐 HTTP GET request',           sev: 'HIGH' },
  HTTP_POST:           { label: '🌐 HTTP POST request',          sev: 'HIGH' },
  HTTP_REQUEST:        { label: '🌐 HTTP request',               sev: 'HIGH' },
  HTTP_GET_game:       { label: '🌐 game:HttpGet',               sev: 'HIGH' },
  HTTP_GET_Async:      { label: '🌐 game:HttpGetAsync',          sev: 'HIGH' },
  NET_request:         { label: '🌐 syn.request / http.request', sev: 'HIGH' },
  SYN_request:         { label: '🌐 syn.request',                sev: 'HIGH' },
  REMOTE_FireServer:   { label: '📡 RemoteEvent:FireServer',     sev: 'MEDIUM' },
  REMOTE_FireAllClients:{ label: '📡 RemoteEvent:FireAllClients',sev: 'MEDIUM' },
  REMOTE_FireClient:   { label: '📡 RemoteEvent:FireClient',     sev: 'MEDIUM' },
  REMOTE_InvokeServer: { label: '📡 RemoteFunction:InvokeServer',sev: 'MEDIUM' },
  DS_SetAsync:         { label: '💾 DataStore:SetAsync',         sev: 'HIGH' },
  DS_UpdateAsync:      { label: '💾 DataStore:UpdateAsync',      sev: 'HIGH' },
  DS_RemoveAsync:      { label: '💾 DataStore:RemoveAsync',      sev: 'HIGH' },
  DS_GetAsync:         { label: '📖 DataStore:GetAsync',         sev: 'LOW' },
  MSG_Publish:         { label: '📨 MessagingService:Publish',   sev: 'HIGH' },
  TELEPORT:            { label: '🚀 Teleport to PlaceId',        sev: 'HIGH' },
  TELEPORT_Async:      { label: '🚀 TeleportAsync',             sev: 'HIGH' },
  TELEPORT_Private:    { label: '🚀 TeleportToPrivateServer',   sev: 'CRITICAL' },
  MKT_PromptProduct:   { label: '💰 Prompt product purchase',   sev: 'HIGH' },
  MKT_PromptGamePass:  { label: '💰 Prompt gamepass purchase',  sev: 'HIGH' },
  MKT_PromptPurchase:  { label: '💰 Prompt purchase',           sev: 'HIGH' },
  PLAYER_Kick:         { label: '👢 Player:Kick',               sev: 'HIGH' },
  CHAT_Send:           { label: '💬 Chat.Chat send',            sev: 'HIGH' },
  TextChatService_Send:{ label: '💬 TextChatService send',      sev: 'HIGH' },
  CLIPBOARD_set:       { label: '📋 setclipboard',              sev: 'HIGH' },
  FS_writefile:        { label: '🗂️ writefile',                 sev: 'HIGH' },
  FS_readfile:         { label: '🗂️ readfile',                  sev: 'MEDIUM' },
  FS_listfiles:        { label: '🗂️ listfiles',                 sev: 'MEDIUM' },
  SCRIPT_INJECT:       { label: '💉 Script Instance injection', sev: 'CRITICAL' },
  loadstring:          { label: '⚙️ loadstring() called',       sev: 'CRITICAL' },
  EXEC_hookfunction:   { label: '🔧 hookfunction',              sev: 'CRITICAL' },
  EXEC_newcclosure:    { label: '🔧 newcclosure',               sev: 'HIGH' },
  EXEC_getupvalues:    { label: '🔧 getupvalues',               sev: 'HIGH' },
  EXEC_decompile:      { label: '🔧 decompile()',               sev: 'MEDIUM' },
  SYN_queue_teleport:  { label: '🚀 syn.queue_on_teleport',     sev: 'CRITICAL' },
  GetService:          { label: 'ℹ️ GetService',                sev: 'INFO' },
  Instance_new:        { label: 'ℹ️ Instance.new',              sev: 'INFO' },
  require:             { label: 'ℹ️ require()',                 sev: 'INFO' },
};

const SEV_ORDER = { CRITICAL:0, HIGH:1, MEDIUM:2, LOW:3, INFO:4 };
const SEV_EMOJI = { CRITICAL:'🔴', HIGH:'🟠', MEDIUM:'🟡', LOW:'🟢', INFO:'⚪' };
const SEV_COLOR = { CRITICAL:0xff0000, HIGH:0xff6600, MEDIUM:0xffcc00, LOW:0x00cc44, INFO:0x8888aa };

function parseSandboxOutput(rawOut) {
  const lines    = rawOut.split('\n');
  const events   = [];
  const prints   = [];
  const errors   = [];
  const warnings = [];
  const calls    = new Map(); // event → {info, count, args[]}

  for (const line of lines) {
    if (!line.startsWith('[NF]\t')) continue;
    const parts = line.slice(5).split('\t');
    const event = parts[0];
    const args  = parts.slice(1);

    if (event === 'print')          { prints.push(args.join('  ')); continue; }
    if (event === 'warn')           { warnings.push(args.join('  ')); continue; }
    if (event === 'pcall_error' || event === 'xpcall_error' ||
        event === 'loadstring_compile_error' || event.endsWith('_error')) {
      errors.push(args.join('  ')); continue;
    }
    if (event === 'SANDBOX_READY')  continue;

    events.push({ event, args });

    const info = BEHAVIOR_MAP[event];
    if (info) {
      const key = event;
      if (!calls.has(key)) calls.set(key, { info, args: [], count: 0 });
      const entry = calls.get(key);
      entry.count++;
      if (entry.args.length < 3) entry.args.push(args.filter(a => a).join(' | '));
    }
  }

  // Build behaviors list sorted by severity
  const behaviors = [...calls.values()]
    .filter(({ info }) => info.sev !== 'INFO')
    .sort((a,b) => SEV_ORDER[a.info.sev] - SEV_ORDER[b.info.sev]);

  const infoItems = [...calls.values()]
    .filter(({ info }) => info.sev === 'INFO');

  return { events, prints, warnings, errors, behaviors, infoItems, calls };
}

// ─── Execute script in lune sandbox ──────────────────────────────────────────
const SANDBOX_PREAMBLE = (() => {
  try { return require('fs').readFileSync(path.join(__dirname, 'sandbox.luau'), 'utf8'); }
  catch { return '-- sandbox.luau not found\n'; }
})();

const TEMP_DIR = path.join(os.tmpdir(), 'nightfall-sandbox');

let luneBin = null;
async function getLune() {
  if (!luneBin) luneBin = await ensureLune();
  return luneBin;
}

async function executeInSandbox(script) {
  const id   = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const file = path.join(TEMP_DIR, `${id}.luau`);

  await mkdir(TEMP_DIR, { recursive: true });
  await writeFile(file, SANDBOX_PREAMBLE + '\n\n' + script, 'utf8');

  const lune = await getLune();
  let stdout = '', stderr = '';

  try {
    const result = await execFileAsync(lune, ['run', file], {
      timeout: EXEC_TIMEOUT,
      maxBuffer: 5 * 1024 * 1024,
    });
    stdout = result.stdout || '';
    stderr = result.stderr || '';
  } catch (err) {
    stdout = err.stdout || '';
    stderr = err.stderr || err.message || '';
    if (err.killed || /timeout|SIGKILL/i.test(String(err))) {
      stderr = '⏱️ Script timed out after ' + (EXEC_TIMEOUT/1000) + 's — possible infinite loop.';
    }
  } finally {
    await unlink(file).catch(() => {});
  }

  return { stdout, stderr };
}

// ─── Response builder ─────────────────────────────────────────────────────────
async function processAndBuild(scriptSrc) {
  const obfuscator = detectObfuscator(scriptSrc);
  const deobbed    = deobfuscate(scriptSrc);

  let stdout = '', stderr = '', sandboxError = null;
  try {
    ({ stdout, stderr } = await executeInSandbox(deobbed));
  } catch (err) {
    sandboxError = String(err);
  }

  const parsed = parseSandboxOutput(stdout);
  const topSev = parsed.behaviors[0]?.info.sev ?? 'INFO';
  const color  = SEV_COLOR[topSev] ?? 0x8888aa;

  const embed = new EmbedBuilder()
    .setColor(color)
    .setTitle('🔬 Nightfall Sandbox Result')
    .setTimestamp()
    .setFooter({ text: 'Deobfuscated → Executed in lune Luau VM' });

  // Row 1: obfuscator + size
  embed.addFields(
    { name: '🔍 Obfuscator',  value: obfuscator ?? 'None / clean', inline: true },
    { name: '📏 Size',        value: `${scriptSrc.length.toLocaleString()} → ${deobbed.length.toLocaleString()} chars`, inline: true },
  );

  // Row 2: behaviors
  if (parsed.behaviors.length > 0) {
    const lines = parsed.behaviors.map(({ info, count, args }) => {
      const detail = args[0] ? ` — \`${args[0].slice(0,60)}\`` : '';
      const times  = count > 1 ? ` ×${count}` : '';
      return `${SEV_EMOJI[info.sev]} **${info.sev}** ${info.label}${times}${detail}`;
    });
    embed.addFields({ name: '⚠️ Runtime Behaviors', value: lines.join('\n').slice(0, 1024) });
  } else {
    embed.addFields({ name: '✅ Runtime Behaviors', value: '🟢 No suspicious behaviors observed during execution.' });
  }

  // Script output (print/warn)
  if (parsed.prints.length > 0) {
    const out = parsed.prints.slice(0, 10).map(l => `> ${l}`).join('\n');
    embed.addFields({ name: '📋 Script Output (print)', value: out.slice(0, 900) });
  }
  if (parsed.warnings.length > 0) {
    const out = parsed.warnings.slice(0, 5).map(l => `⚠ ${l}`).join('\n');
    embed.addFields({ name: '⚠️ Warnings', value: out.slice(0, 500) });
  }

  // Runtime errors
  const errs = [...parsed.errors];
  if (stderr && !stderr.includes('[NF]')) errs.push(stderr.slice(0, 300));
  if (sandboxError) errs.push(sandboxError.slice(0, 200));
  if (errs.length > 0) {
    embed.addFields({ name: '🛑 Runtime Errors', value: errs.slice(0, 3).join('\n').slice(0, 700) });
  }

  // Files
  const files = [];
  if (deobbed.length > 1500) {
    files.push(new AttachmentBuilder(Buffer.from(deobbed, 'utf8'), { name: 'deobfuscated.lua' }));
    embed.addFields({ name: '📄 Deobfuscated Script', value: '📎 Attached as `deobfuscated.lua`' });
  } else {
    embed.addFields({ name: '📄 Deobfuscated Script', value: `\`\`\`lua\n${deobbed.slice(0, 1400)}\n\`\`\`` });
  }

  // Full trace log
  if (parsed.events.length > 0) {
    const traceLines = parsed.events
      .filter(e => e.event !== 'SANDBOX_READY')
      .map(e => `[${e.event}] ${e.args.join(' | ')}`)
      .join('\n');
    if (traceLines.length > 100) {
      files.push(new AttachmentBuilder(Buffer.from(traceLines, 'utf8'), { name: 'trace.log' }));
      embed.addFields({ name: '🧾 Full API Trace', value: '📎 Attached as `trace.log`' });
    }
  }

  return { embed, files };
}

// ─── Script resolvers ─────────────────────────────────────────────────────────
function stripFences(src) {
  return src.replace(/^```(?:lua|luau|txt)?\n?/i, '').replace(/```$/i, '').trim();
}

async function fetchText(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  if (text.length > MAX_SIZE) throw new Error('File too large');
  return text;
}

async function scriptFromInteraction(interaction) {
  const att = interaction.options.getAttachment('file');
  if (att) return stripFences(await fetchText(att.url));
  const inline = interaction.options.getString('script');
  return inline ? stripFences(inline) : null;
}

async function scriptFromMessage(message, inline) {
  const att = message.attachments.find(a => /\.(lua|luau|txt)$/i.test(a.name ?? ''));
  if (att) return stripFences(await fetchText(att.url));
  return inline || null;
}

// ─── Discord setup ────────────────────────────────────────────────────────────
const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
});

const SLASH = [
  new SlashCommandBuilder()
    .setName('sandbox')
    .setDescription('Deobfuscate + execute a Luau script in the Roblox mock VM')
    .addStringOption(o => o.setName('script').setDescription('Paste script here').setRequired(false))
    .addAttachmentOption(o => o.setName('file').setDescription('.lua / .txt file').setRequired(false))
    .toJSON(),
];

const PREFIXES = ['!sandbox', '!deob', '.sandbox', '.deob'];

client.once('ready', async () => {
  console.log(`✅  ${client.user.tag} online`);
  // Pre-warm lune
  getLune().then(() => console.log('✅  lune ready')).catch(e => console.warn('⚠️  lune:', e.message));
  const rest = new REST({ version: '10' }).setToken(TOKEN);
  await rest.put(Routes.applicationCommands(CLIENT_ID), { body: SLASH });
  console.log('✅  Slash commands registered');
});

client.on('interactionCreate', async interaction => {
  if (!interaction.isChatInputCommand() || interaction.commandName !== 'sandbox') return;
  await interaction.deferReply();
  const src = await scriptFromInteraction(interaction).catch(() => null);
  if (!src) return interaction.editReply('❌ No script provided.');
  const { embed, files } = await processAndBuild(src);
  await interaction.editReply({ embeds: [embed], files });
});

client.on('messageCreate', async message => {
  if (message.author.bot) return;
  const content = message.content.trim();
  const cmd = PREFIXES.find(p => content.toLowerCase().startsWith(p));
  if (!cmd) return;

  const inline = content.slice(cmd.length).trim();
  const src = await scriptFromMessage(message, inline).catch(() => null);
  if (!src) return message.reply('❌ No script provided. Paste after the command or attach a `.lua` file.');

  const typing = message.channel.sendTyping().catch(() => {});
  try {
    const { embed, files } = await processAndBuild(src);
    await message.reply({ embeds: [embed], files });
  } catch (err) {
    console.error(err);
    await message.reply(`❌ Error: ${err.message}`);
  }
});

client.login(TOKEN);
