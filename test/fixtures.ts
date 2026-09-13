import path from 'node:path';

import {fs, net, tempDir, zip} from '@appium/support';

import {getPkgRoot} from '../src/utils/index.js';

// Same pre-built, simulator-signed fixture app appium-xcuitest-driver's own test suite downloads
// (test/setup.ts there) — a real .app bundle is required to exercise install/launch/permission
// APIs; building one from scratch isn't reliably reproducible across Xcode versions, and this one
// is already vetted. Generic (not tied to a specific iOS version), so it installs on any iOS
// runtime — never tvOS/watchOS/visionOS.
const UICATALOG_URL =
  'https://github.com/appium/ios-uicatalog/releases/download/v4.0.1/UIKitCatalog-iphonesimulator.zip';
export const UICATALOG_BUNDLE_ID = 'com.example.apple-samplecode.UICatalog';

// Resolved from the package root (like getPkgRoot()'s own callers elsewhere), not import.meta.url
// — this file is compiled to lib/test/fixtures.js, and caching relative to that would put the
// download under lib/ instead of the source tree's (gitignored) test/fixtures/.
const UICATALOG_CACHE_PATH = path.join(getPkgRoot(), 'test/fixtures/UIKitCatalog-iphonesimulator.app');

let downloadPromise: Promise<string> | undefined;

/**
 * Downloads and extracts the UIKitCatalog app from GitHub if it isn't already cached locally
 * (never committed — see .gitignore). Memoizes the in-flight promise so concurrent callers within
 * this process share one download.
 */
export async function getUIKitCatalogPath(): Promise<string> {
  if (downloadPromise) {
    return downloadPromise;
  }
  if (await fs.exists(UICATALOG_CACHE_PATH)) {
    return UICATALOG_CACHE_PATH;
  }
  downloadPromise = (async () => {
    await fs.mkdir(path.dirname(UICATALOG_CACHE_PATH), {recursive: true});
    const tmpDir = await tempDir.openDir();
    try {
      const zipPath = path.join(tmpDir, 'UIKitCatalog-iphonesimulator.zip');
      await net.downloadFile(UICATALOG_URL, zipPath);
      const extractDir = path.join(tmpDir, 'extracted');
      await zip.extractAllTo(zipPath, extractDir);
      const [appDir] = await fs.glob('*.app', {cwd: extractDir});
      if (!appDir) {
        throw new Error('Could not find a .app bundle in the extracted UIKitCatalog zip');
      }
      await fs.copyFile(path.join(extractDir, appDir), UICATALOG_CACHE_PATH);
      return UICATALOG_CACHE_PATH;
    } finally {
      await fs.rimraf(tmpDir);
    }
  })();
  try {
    return await downloadPromise;
  } finally {
    downloadPromise = undefined;
  }
}
