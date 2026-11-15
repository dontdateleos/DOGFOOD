// Signing for the TestFlight upload, made fresh on each run through the App Store Connect API,
// so there are no certificates to export or keep in step and no Mac is needed. Adapted from the
// same tool in Rooms (dontdateleos/Rooms tools/asc-sign.mjs), which shares this Apple team.
//   node tools/asc-sign.mjs make     registers the app id (with HealthKit) if it is missing,
//                                    makes a distribution certificate (into a temporary keychain)
//                                    and an App Store profile, both named for this run
//   node tools/asc-sign.mjs cleanup  removes the temporary keychain
// Needs ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (and optionally BUNDLE_ID); writes what it made to
// GITHUB_ENV.
//
// TWO DIFFERENCES FROM ROOMS, both because this team has more than one app:
//  - Certificates are shared by every app on the team, and Apple allows only two distribution
//    certificates. A build waiting for App Review is checked against the certificate that signed
//    it, and fails (ITMS-90035) if that certificate has been revoked. So a certificate that signed
//    a build in review FOR ANY APP ON THE TEAM is never revoked here, and nothing is revoked at
//    all while there is still room for this run's.
//  - The app id is registered here if it is missing, with the HealthKit capability the app's
//    entitlements need; a profile made without it would fail to sign the app.
import { createPrivateKey, sign } from "node:crypto";
import { execFileSync } from "node:child_process";
import { writeFileSync, appendFileSync, mkdirSync, readFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, BUNDLE_ID = "com.touringgroup.dogfood", GITHUB_ENV, GITHUB_RUN_NUMBER = "local" } = process.env;
const APP_NAME = "Dogfood";
const CERT_LIMIT = 2;
const b64u = b => Buffer.from(b).toString("base64url");
function token() {
  const now = Math.floor(Date.now() / 1000);
  const head = b64u(JSON.stringify({ alg:"ES256", kid:ASC_KEY_ID.trim(), typ:"JWT" }));
  const body = b64u(JSON.stringify({ iss:ASC_ISSUER_ID.trim(), iat:now, exp:now + 1100, aud:"appstoreconnect-v1" }));
  const sig = sign("sha256", Buffer.from(`${head}.${body}`), { key:createPrivateKey(ASC_KEY_P8.trim()), dsaEncoding:"ieee-p1363" });
  return `${head}.${body}.${b64u(sig)}`; }
// Apple's API now and then answers 500 or 429 for a request that is fine; those are retried.
async function api(method, path, body, tries = 4) {
  for (let i = 1; ; i++) {
    try { return await apiOnce(method, path, body); }
    catch (e) { if (i >= tries || !/→ (5\d\d|429):/.test(e.message)) throw e;
      console.log(`${e.message.slice(0, 120)} — trying again (${i} of ${tries - 1})`);
      await new Promise(r => setTimeout(r, 5000 * i * i)); } } }
async function apiOnce(method, path, body) {
  const r = await fetch(`https://api.appstoreconnect.apple.com${path}`, { method,
    headers:{ Authorization:`Bearer ${token()}`, "Content-Type":"application/json" }, body:body ? JSON.stringify(body) : undefined });
  const text = await r.text(); const j = text ? JSON.parse(text) : {};
  if (!r.ok) throw new Error(`${method} ${path} → ${r.status}: ${(j.errors || []).map(e => e.detail || e.title).join("; ") || text.slice(0, 300)}`);
  return j; }
const env = (k, v) => { if (GITHUB_ENV) appendFileSync(GITHUB_ENV, `${k}=${v}\n`); console.log(`${k}=${v}`); };
const sh = (cmd, args, opts = {}) => execFileSync(cmd, args, { stdio:["ignore", "pipe", "inherit"], ...opts }).toString();

/* The app id, registered if missing, with HealthKit switched on. */
async function ensureBundleId() {
  const ids = await api("GET", `/v1/bundleIds?filter[identifier]=${encodeURIComponent(BUNDLE_ID)}&limit=5`);
  let bundle = (ids.data || []).find(b => b.attributes.identifier === BUNDLE_ID);
  if (!bundle) {
    bundle = (await api("POST", "/v1/bundleIds", { data:{ type:"bundleIds", attributes:{ identifier:BUNDLE_ID, name:APP_NAME, platform:"IOS" } } })).data;
    console.log(`registered the app id ${BUNDLE_ID}`); }
  const caps = await api("GET", `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`);
  if (!(caps.data || []).some(c => c.attributes.capabilityType === "HEALTHKIT")) {
    await api("POST", "/v1/bundleIdCapabilities", { data:{ type:"bundleIdCapabilities", attributes:{ capabilityType:"HEALTHKIT" },
      relationships:{ bundleId:{ data:{ type:"bundleIds", id:bundle.id } } } } });
    console.log("switched on HealthKit for the app id"); }
  return bundle; }

async function make() {
  const bundle = await ensureBundleId();
  /* The upload needs the app to exist in App Store Connect, and that one step can't be done
     through the API. The id is registered above, so it is there to pick when you make it. */
  const app = (await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}`)).data?.[0];
  if (!app) throw new Error(`There's no app for ${BUNDLE_ID} in App Store Connect yet. Make it once: App Store Connect → Apps → + → New App, platform iOS, name ${APP_NAME}, bundle ID ${BUNDLE_ID} (registered for you on this run), SKU dogfood. Then run this workflow again.`);
  const dir = join(tmpdir(), "dogfood-sign"); mkdirSync(dir, { recursive:true });
  await makeRoom();
  /* a distribution certificate from a key made here; LibreSSL (/usr/bin/openssl) writes a .p12
     the macOS keychain can read */
  sh("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", join(dir, "dist.key"), "-out", join(dir, "dist.csr"), "-subj", `/CN=Dogfood TestFlight ${GITHUB_RUN_NUMBER}`]);
  const cert = await api("POST", "/v1/certificates", { data:{ type:"certificates", attributes:{ certificateType:"DISTRIBUTION", csrContent:readFileSync(join(dir, "dist.csr"), "utf8") } } });
  env("ASC_CERT_ID", cert.data.id);
  writeFileSync(join(dir, "dist.cer"), Buffer.from(cert.data.attributes.certificateContent, "base64"));
  sh("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", join(dir, "dist.cer"), "-out", join(dir, "dist.pem")]);
  sh("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", join(dir, "dist.key"), "-in", join(dir, "dist.pem"), "-out", join(dir, "dist.p12"), "-passout", "pass:dogfood"]);
  const kc = join(dir, "dogfood.keychain-db"), pw = "dogfood-ci";
  sh("security", ["create-keychain", "-p", pw, kc]);
  sh("security", ["set-keychain-settings", "-lut", "3600", kc]);
  sh("security", ["unlock-keychain", "-p", pw, kc]);
  sh("security", ["import", join(dir, "dist.p12"), "-k", kc, "-P", "dogfood", "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"]);
  sh("security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", pw, kc]);
  const list = sh("security", ["list-keychains", "-d", "user"]).split("\n").map(s => s.trim().replace(/^"|"$/g, "")).filter(Boolean);
  sh("security", ["list-keychains", "-d", "user", "-s", kc, ...list]);
  env("DOGFOOD_KEYCHAIN", kc);
  /* an App Store profile for the app, signed by that certificate; made after the capability,
     so it carries the HealthKit entitlement */
  const name = `Dogfood TestFlight ${GITHUB_RUN_NUMBER}`;
  const prof = await api("POST", "/v1/profiles", { data:{ type:"profiles", attributes:{ name, profileType:"IOS_APP_STORE" },
    relationships:{ bundleId:{ data:{ type:"bundleIds", id:bundle.id } }, certificates:{ data:[{ type:"certificates", id:cert.data.id }] } } } });
  const uuid = prof.data.attributes.uuid, content = Buffer.from(prof.data.attributes.profileContent, "base64");
  for (const d of [join(homedir(), "Library/MobileDevice/Provisioning Profiles"), join(homedir(), "Library/Developer/Xcode/UserData/Provisioning Profiles")]) {
    mkdirSync(d, { recursive:true }); writeFileSync(join(d, `${uuid}.mobileprovision`), content); }
  env("ASC_PROFILE_ID", prof.data.id); env("ASC_PROFILE_NAME", name); env("ASC_PROFILE_UUID", uuid); }

/* Room for this run's certificate, without touching any certificate a build in review needs.
   A build's signer is the newest certificate made before it was uploaded (certificates last a
   year, so one was made a year before it expires). */
const madeAt = c => new Date(c.attributes.expirationDate).getTime() - 365 * 864e5;
async function makeRoom() {
  const certs = ((await api("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50")).data || []).sort((a, b) => madeAt(b) - madeAt(a));
  if (certs.length < CERT_LIMIT) { console.log(`${certs.length} distribution certificate(s) on the team; room for one more, nothing revoked`); }
  else {
    const keep = new Set();
    try {
      const apps = (await api("GET", "/v1/apps?limit=200")).data || [];
      for (const app of apps) {
        const versions = (await api("GET", `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&limit=10`)).data || [];
        for (const v of versions) {
          if (!/WAITING_FOR_REVIEW|IN_REVIEW|PENDING_DEVELOPER_RELEASE|PENDING_APPLE_RELEASE|PROCESSING_FOR_APP_STORE|PREPARE_FOR_SUBMISSION|READY_FOR_REVIEW|DEVELOPER_REJECTED|REJECTED/.test(v.attributes.appStoreState || "")) continue;
          const b = (await api("GET", `/v1/appStoreVersions/${v.id}/build`).catch(() => ({}))).data;
          if (!b) continue;
          const up = new Date(b.attributes.uploadedDate).getTime(), signer = certs.find(c => madeAt(c) <= up + 60e3);
          if (signer && !keep.has(signer.id)) { keep.add(signer.id);
            console.log(`keeping the certificate that signed ${app.attributes.name} build ${b.attributes.version} (version ${v.attributes.versionString}, ${v.attributes.appStoreState})`); } } }
    } catch (e) {
      throw new Error(`Couldn't check which certificates builds in review need (${e.message.slice(0, 160)}), so none were revoked. Run it again in a minute.`); }
    const spare = certs.filter(c => !keep.has(c.id)).reverse();   // oldest first
    let over = certs.length - (CERT_LIMIT - 1);
    for (const c of spare) {
      if (over <= 0) break;
      await api("DELETE", `/v1/certificates/${c.id}`);
      console.log(`revoked an old certificate no build in review needs (${c.attributes.displayName || c.id}, expiring ${c.attributes.expirationDate.slice(0, 10)})`);
      over--; }
    if (over > 0) throw new Error("Every distribution certificate on the team signed a build that's in App Review, so there's no room for this run's. Run it again once one of those reviews is finished."); }
  /* this app's profiles from earlier runs whose certificate has gone are no use to anyone */
  const profs = (await api("GET", "/v1/profiles?filter[profileType]=IOS_APP_STORE&limit=100")).data || [];
  for (const p of profs.filter(p => /^Dogfood TestFlight /.test(p.attributes.name) && p.attributes.profileState !== "ACTIVE"))
    await api("DELETE", `/v1/profiles/${p.id}`).then(() => console.log(`deleted the old profile "${p.attributes.name}"`), () => {}); }

async function cleanup() {
  /* the certificate and profile stay: App Review checks a build's signature again on submission */
  const { DOGFOOD_KEYCHAIN } = process.env;
  if (DOGFOOD_KEYCHAIN) try { sh("security", ["delete-keychain", DOGFOOD_KEYCHAIN]); } catch {} }

const what = process.argv[2];
(what === "make" ? make() : what === "cleanup" ? cleanup() : Promise.reject(new Error("make or cleanup")))
  .catch(e => { console.log(`::error::${e.message}`); process.exit(1); });
