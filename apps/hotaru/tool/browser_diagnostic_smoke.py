import asyncio
import datetime
import json
import pathlib
import sys

from playwright.async_api import async_playwright


SNAPSHOT = '''() => ({
  url: location.href,
  fields: Object.fromEntries(Array.from(document.querySelectorAll('[id]'))
    .filter(e => /^(client-ip|rtc-|dns-)/.test(e.id))
    .map(e => [e.id, e.innerText.trim().slice(0, 1500)])),
  resolvers: Array.from(document.querySelectorAll('.dns-table-in tr'))
    .map(row => Array.from(row.querySelectorAll('td')).map(e => e.innerText.trim())),
  buttons: Array.from(document.querySelectorAll('#dns-test'))
    .map(e => ({text: e.innerText, disabled: e.disabled}))
})'''


async def observe(browser, kind):
    context = await browser.new_context(permissions=[])
    page = await context.new_page()
    try:
        await page.goto(f'https://browserleaks.com/{kind}', wait_until='domcontentloaded', timeout=30000)
        if kind == 'dns':
            await page.locator('#dns-test').click(timeout=10000)
        await page.wait_for_timeout(45000 if kind == 'dns' else 12000)
        return {'kind': kind, 'observation': await page.evaluate(SNAPSHOT)}
    except Exception as error:
        return {'kind': kind, 'error': type(error).__name__}
    finally:
        await context.close()


async def main():
    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch()
        try:
            results = await asyncio.gather(*(observe(browser, kind) for kind in ['dns', 'webrtc']))
        finally:
            await browser.close()
    document = {
        'checked_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'scope': 'CI Chromium reference behavior only; not Hotaru WebView2, system proxy, TUN or release acceptance',
        'results': results,
    }
    pathlib.Path(sys.argv[1]).write_text(json.dumps(document, indent=2) + '\n')
    for result in results:
        print(json.dumps(result))


if __name__ == '__main__':
    asyncio.run(main())
