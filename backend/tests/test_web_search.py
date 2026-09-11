import unittest
from unittest.mock import patch

import httpx

from tools.python_executor import PythonExecutor
from tools.web_search import WebSearchClient, WebSearchError


class PublicTestWebClient(WebSearchClient):
    async def _ensure_public(self, value):
        return None


class FakeWeb:
    async def search(self, query, count=5, recency_days=None):
        return {"query":query,"count":count,"recency_days":recency_days}

    async def fetch_page(self, url, max_chars=7000):
        return {"url":url,"max_chars":max_chars}


class WebSearchTests(unittest.IsolatedAsyncioTestCase):
    async def test_bing_rss_results_are_structured_and_time_stamped(self):
        xml=b'''<?xml version="1.0"?><rss><channel><item><title>Ark Result</title><link>https://example.com/news</link><description>Useful &amp; current.</description><pubDate>Sat, 06 Sep 2026 10:00:00 GMT</pubDate></item></channel></rss>'''
        transport=httpx.MockTransport(lambda request:httpx.Response(200,content=xml,headers={"content-type":"application/rss+xml"}))
        async with httpx.AsyncClient(transport=transport) as http:
            client=WebSearchClient(client=http)
            with patch.dict("os.environ",{"ARK_SEARCH_PROVIDER":"bing"}):
                result=await client.search("Ark Intelligence",count=3,recency_days=7)
        self.assertEqual(result["provider"],"bing")
        self.assertEqual(result["results"][0]["url"],"https://example.com/news")
        self.assertIn("after:",result["effective_query"])
        self.assertTrue(result["verified"])

    async def test_fetch_page_extracts_text_and_follows_safe_redirect(self):
        def handler(request):
            if request.url.path=="/start": return httpx.Response(302,headers={"location":"/article"})
            return httpx.Response(200,text="<html><head><title>Title</title></head><body><script>ignore()</script><article><h1>Hello</h1><p>Useful content.</p></article></body></html>",headers={"content-type":"text/html; charset=utf-8"})
        transport=httpx.MockTransport(handler)
        async with httpx.AsyncClient(transport=transport,follow_redirects=False) as http:
            result=await PublicTestWebClient(client=http).fetch_page("https://example.com/start")
        self.assertEqual(result["title"],"Title")
        self.assertIn("Useful content",result["content"])
        self.assertNotIn("ignore",result["content"])
        self.assertEqual(result["final_url"],"https://example.com/article")

    async def test_private_and_non_web_addresses_are_rejected(self):
        client=WebSearchClient(client=httpx.AsyncClient(transport=httpx.MockTransport(lambda _:httpx.Response(200))))
        try:
            for url in ("http://127.0.0.1/private","http://localhost/private","file:///etc/passwd"):
                with self.assertRaises(WebSearchError): await client._ensure_public(url)
        finally:
            await client.client.aclose()

    async def test_python_executor_routes_allowlisted_web_actions(self):
        executor=PythonExecutor(web=FakeWeb())
        search=await executor.execute("web.search",{"query":"news","count":2,"recency_days":1})
        page=await executor.execute("web.fetch_page",{"url":"https://example.com"})
        self.assertEqual(search["count"],2)
        self.assertEqual(page["max_chars"],7000)


if __name__ == "__main__": unittest.main()
