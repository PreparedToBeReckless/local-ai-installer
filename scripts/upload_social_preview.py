#!/usr/bin/env python3
"""Upload GitHub repository social preview via Playwright (Settings UI)."""
import asyncio
import sys
from pathlib import Path

import browser_cookie3
from playwright.async_api import async_playwright

REPO = "PreparedToBeReckless/local-ai-installer"
SETTINGS = f"https://github.com/{REPO}/settings"
IMAGE = Path(__file__).resolve().parents[1] / "assets" / "social-preview-1280x640.png"
STATE = Path(__file__).resolve().parents[1] / ".github-playwright-auth" / "state.json"


def firefox_cookies_for_github():
    cookies = []
    for c in browser_cookie3.firefox(domain_name="github.com"):
        expires = -1
        if c.expires:
            try:
                exp = int(c.expires)
                if exp > 1_000_000_000_000:  # Firefox stores ms timestamps
                    exp //= 1000
                expires = exp if exp > 0 else -1
            except (TypeError, ValueError):
                expires = -1
        cookies.append(
            {
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path or "/",
                "expires": expires,
                "httpOnly": bool(getattr(c, "rest", {}).get("HttpOnly", False)),
                "secure": bool(c.secure),
                "sameSite": "Lax",
            }
        )
    return cookies


async def upload(image: Path, headless: bool = True):
    if not image.is_file():
        raise SystemExit(f"Missing image: {image}")

    STATE.parent.mkdir(parents=True, exist_ok=True)
    storage = str(STATE) if STATE.is_file() else None

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=headless)
        context_kwargs = {"viewport": {"width": 1280, "height": 900}}
        if storage:
            context_kwargs["storage_state"] = storage
        context = await browser.new_context(**context_kwargs)
        if not storage:
            fw = firefox_cookies_for_github()
            if fw:
                await context.add_cookies(fw)
                print(f"Loaded {len(fw)} Firefox cookies for github.com")
        page = await context.new_page()
        await page.goto(SETTINGS, wait_until="domcontentloaded")

        username = await page.evaluate(
            "() => document.querySelector('meta[name=\"user-login\"]')?.content?.trim() || ''"
        )
        if not username or "/login" in page.url:
            if headless:
                await browser.close()
                raise SystemExit(
                    "Not logged into GitHub in Playwright. Re-run with --login (opens browser)."
                )
            print("Log into GitHub in the opened window…")
            await page.wait_for_function(
                "() => document.querySelector('meta[name=\"user-login\"]')?.content?.trim()",
                timeout=300_000,
            )
            await context.storage_state(path=str(STATE))
            await page.goto(SETTINGS, wait_until="domcontentloaded")

        heading = page.locator("xpath=//h2[normalize-space()='Social preview']").first
        await heading.wait_for(state="attached", timeout=60_000)

        edit = page.locator("#edit-social-preview-button")
        if await edit.count():
            await edit.first.click(force=True)

        file_input = page.locator("input#repo-image-file-input")
        upload_item = page.get_by_text("Upload an image", exact=False).first
        await file_input.wait_for(state="attached", timeout=30_000)

        async with page.expect_response(
            lambda r: r.status in range(200, 300)
            and ("/upload/repository-images/" in r.url or "/upload/policies/repository-images" in r.url),
            timeout=30_000,
        ) as upload_wait:
            if await file_input.count():
                await file_input.set_input_files(str(image))
            else:
                async with page.expect_file_chooser() as fc:
                    await upload_item.click(force=True)
                chooser = await fc.value
                await chooser.set_files(str(image))

        try:
            resp = await upload_wait.value
            print(f"Upload OK: {resp.status} {resp.url}")
        except Exception:
            print("Upload response not seen — checking DOM…")

        await page.wait_for_function(
            "() => (document.querySelector('input.js-repository-image-id')?.value || '').trim()",
            timeout=30_000,
        )
        image_id = await page.locator("input.js-repository-image-id").input_value()
        await context.storage_state(path=str(STATE))
        await browser.close()
        print(f"Social preview set (image id: {image_id.strip()})")


def main():
    login = "--login" in sys.argv
    asyncio.run(upload(IMAGE, headless=not login))


if __name__ == "__main__":
    main()