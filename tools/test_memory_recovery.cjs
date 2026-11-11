// Exercise budget recovery during an in-flight multi-batch view.
const fs = require('fs');
const { chromium } = require(process.env.O3DV_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
    const browser = await chromium.launch({ headless: true, args: ['--use-angle=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist'] });
    const page = await browser.newPage({ viewport: { width: 640, height: 700 } });
    const errors = []; page.on('pageerror', e => errors.push(String(e)));
    await page.addInitScript(() => {
        window.O3DVNativeDebug = true; window.events = []; window.delayReads = 0; window.abortedReads = 0;
        window.webkit = { messageHandlers: { o3dv: { postMessage: m => window.events.push(m) } } };
        const original = window.fetch;
        window.fetch = async (...args) => {
            if (String(args[0]).includes('.bin') && window.delayReads) {
                await new Promise((resolve, reject) => {
                    const timer = setTimeout(resolve, window.delayReads);
                    args[1]?.signal?.addEventListener('abort', () => {
                        window.abortedReads++; clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError'));
                    }, { once: true });
                });
            }
            return original(...args);
        };
    });
    await page.goto('http://127.0.0.1:8097/');
    await page.waitForFunction(() => window.O3DVOpenStream);
    const wait = async (expression, arg = null) => {
        await page.waitForFunction(expression, arg, { timeout: 90000 });
        const event = await page.evaluate(expression, arg);
        if (event?.type === 'javascript_error') throw Error(JSON.stringify(event));
        return event;
    };
    const low = 512 * 1024, high = 16 * 1048576;
    await page.evaluate(low => {
        window.O3DVSetMemoryPolicy({ geometryBytes: low, textureBytes: 1048576, framePixels: 1000000 });
        window.O3DVOpenStream(location.origin + '/models/distinct-blocks/manifest.json');
    }, low);
    await wait(() => events.find(e => e.type === 'model_loaded' || e.type === 'javascript_error'));
    await page.evaluate(() => { window.events = []; window.delayReads = 30; window.abortedReads = 0; });
    const box = await page.locator('#viewer').boundingBox();
    await page.mouse.move(box.x + box.width * .5, box.y + box.height * .5);
    await page.mouse.down(); await page.mouse.move(box.x + box.width * .68, box.y + box.height * .57, { steps: 5 }); await page.mouse.up();
    const partial = await wait(() => events.find(e => (e.type === 'stream_view_progress' && !e.complete && e.visibleDone > 0) || e.type === 'javascript_error'));
    if (!partial.previousFrameVisible || !partial.visibleTotal || partial.visibleDone >= partial.visibleTotal) throw Error('Missing useful recovery progress');
    const before = await page.evaluate(() => window.abortedReads);
    await page.evaluate(high => window.O3DVSetMemoryPolicy({ geometryBytes: high, textureBytes: 1048576, framePixels: 1000000 }), high);
    const finish = await wait(serial => events.find(e => (e.type === 'stream_view_progress' && e.complete && e.frameSerial === serial) || e.type === 'javascript_error'), partial.frameSerial);
    if (finish.geometryBudgetBytes !== low || await page.evaluate(() => window.abortedReads) !== before) throw Error('Budget increase interrupted the active frame');
    const warmed = await wait(() => events.find(e => (e.type === 'stream_view_progress' && e.complete && e.geometryBudgetBytes === 16 * 1048576) || e.type === 'javascript_error'));
    if (warmed.residentBytes > high || warmed.peakWorkingBytes > warmed.peakWorkingBudgetBytes) throw Error('Recovery exceeded the geometry budget');
    await page.evaluate(() => { window.delayReads = 0; window.events = []; window.nav = window.O3DVBenchmarkNavigation(); });
    const benchmark = await wait(() => events.find(e => e.type === 'navigation_benchmark_complete' || e.type === 'javascript_error'));
    if (benchmark.results.some(result => result.frameReadRequests !== 0)) throw Error('Recovered cache was not reused');
    if (errors.length) throw Error(errors.join('\n'));
    fs.writeFileSync('build/ios/memory-recovery-tests/browser-results.json', JSON.stringify({ partial, finish, warmed, benchmark }, null, 2));
    console.log('PASS in-flight frame preserved, budget increase deferred, cache warmed, subsequent navigation without reads');
    await browser.close();
})().catch(error => { console.error(error); process.exit(1); });
