/**
 * 用 HarmonyOS SDK 自带的 OpenHarmony 本地 CA 为 HAP 做 debug/release 本地签名。
 * 产物带完整签名块，可被 hap-sign-tool verify-app 验证。
 * 注意：真机分发仍需华为开发者正式证书 + profile（见 README / SPEC）。
 */
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const PROJ = '/workspace/NeoWarpHarmony';
const CLI = '/opt/harmony/command-line-tools';
const LIB = `${CLI}/sdk/default/openharmony/toolchains/lib`;
const JAVA_HOME = process.env.JAVA_HOME || '/root/.sdkman/candidates/java/current';
const JAVA = `${JAVA_HOME}/bin/java`;
const KEYTOOL = `${JAVA_HOME}/bin/keytool`;
const SIGN = `${LIB}/hap-sign-tool.jar`;
const STORE = `${LIB}/OpenHarmony.p12`;
const STORE_PWD = '123456';
const DIR = `${PROJ}/signing`;
const DIST = `${PROJ}/dist`;
const UNSIGNED = `${PROJ}/entry/build/default/outputs/default/entry-default-unsigned.hap`;
const SIGNED = `${DIST}/NeoWarp-0.0.1-harmony.hap`;

fs.mkdirSync(DIR, { recursive: true });
fs.mkdirSync(DIST, { recursive: true });
if (!fs.existsSync(UNSIGNED)) {
  throw new Error(`未找到 hvigor 产物：${UNSIGNED}，请先执行 hvigorw assembleHap`);
}

const run = (bin, args, label) => {
  console.log(`\n=== ${label} ===`);
  const out = execFileSync(bin, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (out.trim()) console.log(out.trim().slice(0, 1200));
};

// 1. 导出 SDK 自带应用证书链（三级：leaf / 应用 CA / 根 CA）
//    hap-sign-tool sign-app 要求 appCertFile 为完整证书链，单张 leaf 会被拒绝。
const exportCert = (alias, file) => run(KEYTOOL, ['-exportcert', '-rfc', '-alias', alias,
  '-keystore', STORE, '-storepass', STORE_PWD, '-file', file], `导出 ${alias}`);
const APP_CER = `${DIR}/app-release.cer`;
const SUB_CA_CER = `${DIR}/app-ca.cer`;
const ROOT_CA_CER = `${DIR}/app-root-ca.cer`;
const APP_CHAIN = `${DIR}/app-release-chain.cer`;
exportCert('openharmony application release', APP_CER);
exportCert('openharmony application ca', SUB_CA_CER);
exportCert('openharmony application root ca', ROOT_CA_CER);
// leaf 必须用 profile 模板中的分发证书（由「OpenHarmony Application CA」签发），
// keytool 从 p12 导出的同名证书是自签的，与之不是同一张，直接拼接会导致链签名校验失败。
const DIST_CERT = JSON.parse(
  fs.readFileSync(`${LIB}/UnsgnedReleasedProfileTemplate.json`, 'utf8')
)['bundle-info']['distribution-certificate'];
fs.writeFileSync(APP_CHAIN,
  DIST_CERT + fs.readFileSync(SUB_CA_CER, 'utf8') + fs.readFileSync(ROOT_CA_CER, 'utf8'));
console.log(`应用证书链张数: ${(fs.readFileSync(APP_CHAIN, 'utf8').match(/BEGIN CERTIFICATE/g) || []).length}`);

// 2. 构造 Provision Profile：bundleName 对齐工程，有效期为当前时间起 10 年
const template = JSON.parse(fs.readFileSync(`${LIB}/UnsgnedReleasedProfileTemplate.json`, 'utf8'));
const now = Math.floor(Date.now() / 1000);
template['version-name'] = '0.0.1';
template['version-code'] = 1;
template.uuid = 'a3f1c2d4-7b8e-4c90-9a12-6e5f4d3c2b10';
template.validity = { 'not-before': now - 86400, 'not-after': now + 10 * 365 * 86400 };
template['bundle-info']['bundle-name'] = 'org.neowarp.harmony';
template['bundle-info']['developer-id'] = 'NeoWarp';
const PROFILE_JSON = `${DIR}/profile.json`;
fs.writeFileSync(PROFILE_JSON, JSON.stringify(template, null, 2));
console.log(`\n=== Profile ===\nbundle-name: ${template['bundle-info']['bundle-name']} | type: ${template.type} | validity: ${template.validity['not-before']} ~ ${template.validity['not-after']}`);

// 3. 用 SDK Profile Release 私钥签 provision profile
const PROFILE_P7B = `${DIR}/profile.p7b`;
run(JAVA, ['-jar', SIGN, 'sign-profile', '-mode', 'localSign',
  '-keyAlias', 'openharmony application profile release', '-keyPwd', STORE_PWD,
  '-profileCertFile', `${LIB}/OpenHarmonyProfileRelease.pem`,
  '-inFile', PROFILE_JSON, '-signAlg', 'SHA256withECDSA',
  '-keystoreFile', STORE, '-keystorePwd', STORE_PWD,
  '-outFile', PROFILE_P7B], '签名 Provision Profile');

// 4. 签 HAP
run(JAVA, ['-jar', SIGN, 'sign-app', '-mode', 'localSign',
  '-keyAlias', 'openharmony application release', '-keyPwd', STORE_PWD,
  '-appCertFile', APP_CHAIN, '-profileFile', PROFILE_P7B,
  '-inFile', UNSIGNED, '-signAlg', 'SHA256withECDSA',
  '-keystoreFile', STORE, '-keystorePwd', STORE_PWD,
  '-outFile', SIGNED, '-compatibleVersion', '26'], '签名 HAP');

// 5. 验证签名块
const VERIFY = `${DIR}/verify-app.json`;
try {
  run(JAVA, ['-jar', SIGN, 'verify-app', '-inFile', SIGNED, '-outFile', VERIFY], '验证签名');
  console.log(fs.readFileSync(VERIFY, 'utf8').slice(0, 900));
} catch (e) {
  console.log('verify-app 输出:', e.stdout?.slice(0, 500) || '', e.stderr?.slice(0, 500) || '');
}

console.log(`\n=== 完成 ===\n签名 HAP: ${SIGNED} (${(fs.statSync(SIGNED).size / 1048576).toFixed(2)} MB)`);
