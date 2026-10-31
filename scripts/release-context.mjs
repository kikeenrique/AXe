#!/usr/bin/env node

import process from 'node:process';

function parseArgs(argv) {
  const args = {
    commitSha: '',
    mode: '',
    requestedRef: '',
    runNumber: '',
    signing: '',
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = argv[index + 1];

    if (arg === '--mode') {
      args.mode = next ?? '';
      index += 1;
      continue;
    }

    if (arg === '--requested-ref') {
      args.requestedRef = next ?? '';
      index += 1;
      continue;
    }

    if (arg === '--commit-sha') {
      args.commitSha = next ?? '';
      index += 1;
      continue;
    }

    if (arg === '--run-number') {
      args.runNumber = next ?? '';
      index += 1;
      continue;
    }

    if (arg === '--signing') {
      args.signing = next ?? '';
      index += 1;
      continue;
    }

    if (arg === '--help' || arg === '-h') {
      printHelp();
      process.exit(0);
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!args.mode || !args.requestedRef || !args.commitSha || !args.runNumber || !args.signing) {
    throw new Error('Missing required arguments. Expected --mode, --requested-ref, --commit-sha, --run-number, and --signing');
  }

  if (args.signing !== 'available' && args.signing !== 'unavailable') {
    throw new Error(`Invalid --signing value: ${args.signing}. Expected available or unavailable`);
  }

  return args;
}

function printHelp() {
  console.log(`Resolve AXe release workflow context.

Usage:
  node scripts/release-context.mjs --mode <mode> --requested-ref <ref> --commit-sha <sha> --run-number <n> --signing <available|unavailable>

Modes:
  production-shipping
  production-verify
  staging-publish
  staging-validate

Signing:
  available     Developer ID certificate and notarization secrets are all set
  unavailable   At least one of them is missing. The build is staged from the build
                output without notarization: staging-publish publishes an unsigned
                prerelease, production-shipping an unsigned release, both titled
                with an "(unsigned)" marker; production-verify uploads unsigned artifacts.
`);
}

function isPrerelease(version) {
  return version.includes('-');
}

function trimRefPrefix(value) {
  return value.replace(/^refs\/tags\//, '').replace(/^refs\/heads\//, '');
}

function shortSha(value) {
  return value.slice(0, 7);
}

function refLabel(value) {
  const trimmed = trimRefPrefix(value);
  const normalized = trimmed.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '');
  return normalized || 'ref';
}

function buildStagingContext({ mode, requestedRef, commitSha, runNumber, signing }) {
  const publish = mode === 'staging-publish';
  const signed = signing === 'available';
  const notarized = publish && signed;
  const sha = shortSha(commitSha);
  const refName = refLabel(requestedRef);
  const version = `0.0.0-staging.${runNumber}`;
  const releaseTag = publish ? `staging-${refName}-${runNumber}-${sha}` : `staging-validate-${refName}-${runNumber}-${sha}`;
  const baseTitle = publish ? `Staging ${releaseTag}` : `Staging validation ${releaseTag}`;
  const releaseTitle = publish && !signed ? `${baseTitle} (unsigned)` : baseTitle;

  return {
    channel: 'staging',
    mode,
    requestedRef,
    commitSha,
    releaseTag,
    releaseTitle,
    version,
    prerelease: 'true',
    publishRelease: publish ? 'true' : 'false',
    uploadArtifacts: publish ? 'false' : 'true',
    updateTapTarget: publish ? 'staging' : 'none',
    notesMode: publish ? 'staging' : 'none',
    stageSource: notarized ? 'notarized-package' : 'build-output',
    signed: signed ? 'true' : 'false',
    releaseTarget: commitSha,
  };
}

function buildContext({ mode, requestedRef, commitSha, runNumber, signing }) {
  if (mode === 'production-shipping' || mode === 'production-verify') {
    const signed = signing === 'available';
    const tag = trimRefPrefix(requestedRef);
    if (!tag.startsWith('v')) {
      throw new Error(`Production mode requires a version tag ref, got: ${requestedRef}`);
    }

    const version = tag.slice(1);
    const prerelease = isPrerelease(version);

    return {
      channel: 'production',
      mode,
      requestedRef,
      commitSha,
      releaseTag: tag,
      releaseTitle: signed || mode !== 'production-shipping' ? `Release ${tag}` : `Release ${tag} (unsigned)`,
      version,
      prerelease: prerelease ? 'true' : 'false',
      publishRelease: mode === 'production-shipping' ? 'true' : 'false',
      uploadArtifacts: mode === 'production-verify' ? 'true' : 'false',
      updateTapTarget: mode === 'production-shipping' ? (prerelease ? 'staging' : 'production') : 'none',
      notesMode: mode === 'production-shipping' ? 'changelog' : 'none',
      stageSource: signed ? 'notarized-package' : 'build-output',
      signed: signed ? 'true' : 'false',
      releaseTarget: commitSha,
    };
  }

  if (mode === 'staging-publish' || mode === 'staging-validate') {
    return buildStagingContext({ mode, requestedRef, commitSha, runNumber, signing });
  }

  throw new Error(`Unsupported mode: ${mode}`);
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    const context = buildContext(args);

    for (const [key, value] of Object.entries(context)) {
      process.stdout.write(`${key}=${value}\n`);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`Error: ${message}\n`);
    process.exit(1);
  }
}

main();
