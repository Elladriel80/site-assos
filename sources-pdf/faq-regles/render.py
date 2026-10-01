from playwright.sync_api import sync_playwright
import pathlib
p=pathlib.Path('faq.html').resolve()
with sync_playwright() as pw:
    b=pw.chromium.launch()
    pg=b.new_page()
    pg.goto(p.as_uri()); pg.wait_for_load_state('networkidle')
    pg.pdf(path='faq-regles-interregions-2026.pdf', format='A4', print_background=True, prefer_css_page_size=True)
    b.close()
