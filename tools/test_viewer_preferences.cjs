const fs = require('fs');
const { chromium } = require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
    const base = fs.readFileSync('build/ios/gltf-stream-tests/server-url.txt', 'utf8').trim();
    const browser = await chromium.launch({ headless: true, args: ['--use-angle=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist'] });
    const page = await browser.newPage({ viewport: { width: 800, height: 650 } });
    const errors = [];
    page.on('pageerror', error => errors.push(String(error)));
    await page.addInitScript(() => {
        window.O3DVNativeDebug = true;
        window.events = [];
        window.webkit = { messageHandlers: { o3dv: { postMessage: message => window.events.push(message) } } };
    });
    await page.goto(base);
    await page.waitForFunction(() => window.O3DVSetViewerPreferences && window.events.some(e => e.type === 'ready'));
    for (const [preferences, expected] of [
        [{ background: 'dark', navigation: 'fixed', projection: 'orthographic' }, { background: 42, navigation: 1, projection: 2 }],
        [{ background: 'light', navigation: 'free', projection: 'perspective' }, { background: 255, navigation: 2, projection: 1 }]
    ]) {
        const actual = await page.evaluate(preferences => {
            window.O3DVSetViewerPreferences(preferences);
            return window.O3DVGetViewerPreferences();
        }, preferences);
        if (JSON.stringify(actual) !== JSON.stringify(expected)) throw Error(JSON.stringify({ actual, expected }));
    }
    const hidden = await page.evaluate(() => ['fix_up_on', 'camera_perspective', 'dark_mode'].every(icon =>
        getComputedStyle(document.querySelector(`[data-icon="${icon}"]`)).display === 'none'));
    if (!hidden || errors.length) throw Error(JSON.stringify({ hidden, errors }));
    await page.evaluate(() => { window.O3DVOpenStream(location.origin + '/imports/build/ios/hatch-tests/caches/work-3/manifest.json'); });
    await page.waitForFunction(() => window.events.some(e => ['model_loaded', 'javascript_error'].includes(e.type)), null, { timeout: 30000 });
    const loaded = await page.evaluate(() => window.events.find(e => ['model_loaded', 'javascript_error'].includes(e.type)));
    if (loaded.type !== 'model_loaded') throw Error(JSON.stringify({ loaded, errors }));
    await page.evaluate(() => {
        window.events = [];
        window.O3DVSetViewerPreferences({ background: 'dark', navigation: 'fixed', projection: 'orthographic' });
    });
    await page.waitForFunction(() => window.events.some(e => (e.type === 'stream_view_progress' && e.complete) || e.type === 'javascript_error'), null, { timeout: 30000 });
    const state = await page.evaluate(() => ({ preferences: window.O3DVGetViewerPreferences(),
        frame: window.events.find(e => e.type === 'stream_view_progress' && e.complete) }));
    if (state.preferences.background !== 42 || state.preferences.navigation !== 1 || state.preferences.projection !== 2 ||
        state.frame.displayed !== state.frame.total || errors.length) throw Error(JSON.stringify({ state, errors }));
    await page.screenshot({ path: 'build/ios/settings-loading-tests/dark-cad.png' });
    console.log('PASS background, orbit, projection and native toolbar with loaded CAD');
    await browser.close();
})().catch(error => { console.error(error); process.exit(1); });
