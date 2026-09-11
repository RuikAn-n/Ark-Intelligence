"""Small keyless web search and safe public-page reader."""
import asyncio
import html
import ipaddress
import os
import re
import socket
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from urllib.parse import parse_qs, unquote, urljoin, urlparse

import httpx


class WebSearchError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code=code


def _clean(value):
    value=html.unescape(re.sub(r'<[^>]+>',' ',value or ''))
    return re.sub(r'\s+',' ',value).strip()


def _safe_result_url(value):
    try:
        if len(value)>1200: return None
        parsed=urlparse(value)
        if parsed.scheme not in {'http','https'} or not parsed.hostname or parsed.username or parsed.password:
            return None
        if parsed.port and parsed.port not in {80,443}: return None
        host=parsed.hostname.rstrip('.').lower()
        if host in {'localhost','localhost.localdomain'} or host.endswith(('.local','.internal','.lan','.home','.test')):
            return None
        try:
            address=ipaddress.ip_address(host.split('%')[0])
            if not address.is_global: return None
        except ValueError:
            pass
        return value
    except ValueError:
        return None


class _DuckDuckGoParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.results=[];self.capture=None;self.buffer=[];self.href=None

    def handle_starttag(self,tag,attrs):
        values=dict(attrs);classes=set(values.get('class','').split())
        if tag=='a' and 'result__a' in classes:
            self.capture='title';self.buffer=[];self.href=values.get('href')
        elif 'result__snippet' in classes:
            self.capture='snippet';self.buffer=[]

    def handle_data(self,data):
        if self.capture: self.buffer.append(data)

    def handle_endtag(self,tag):
        if self.capture=='title' and tag=='a':
            href=self.href or ''
            parsed=urlparse(urljoin('https://duckduckgo.com',href))
            target=parse_qs(parsed.query).get('uddg',[href])[0]
            target=unquote(target)
            if (safe:=_safe_result_url(target)):
                self.results.append({'title':_clean(''.join(self.buffer)),'url':safe,'snippet':'','published_at':None})
            self.capture=None
        elif self.capture=='snippet' and tag in {'a','div','span'}:
            if self.results: self.results[-1]['snippet']=_clean(''.join(self.buffer))
            self.capture=None


class _PageTextParser(HTMLParser):
    skip_tags={'script','style','noscript','svg','canvas','form'}
    block_tags={'p','div','article','section','main','h1','h2','h3','h4','li','br','tr','blockquote'}

    def __init__(self):
        super().__init__()
        self.skip=0;self.parts=[];self.in_title=False;self.title=[]

    def handle_starttag(self,tag,attrs):
        if tag in self.skip_tags: self.skip+=1
        if tag=='title': self.in_title=True
        if not self.skip and tag in self.block_tags: self.parts.append('\n')

    def handle_endtag(self,tag):
        if tag in self.skip_tags and self.skip: self.skip-=1
        if tag=='title': self.in_title=False
        if not self.skip and tag in self.block_tags: self.parts.append('\n')

    def handle_data(self,data):
        if self.in_title: self.title.append(data)
        if not self.skip: self.parts.append(data)

    def output(self):
        text=html.unescape(' '.join(self.parts))
        text=re.sub(r'[ \t\f\v]+',' ',text)
        text=re.sub(r' *\n *','\n',text)
        text=re.sub(r'\n{3,}','\n\n',text).strip()
        return _clean(''.join(self.title)),text


class WebSearchClient:
    user_agent='ArkIntelligence/1.0 (+local personal agent)'

    def __init__(self, client=None):
        self.client=client or httpx.AsyncClient(
            timeout=httpx.Timeout(12,connect=5),
            limits=httpx.Limits(max_connections=4,max_keepalive_connections=2),
            follow_redirects=False,
            trust_env=False,
            headers={'User-Agent':self.user_agent,'Accept-Language':'zh-CN,zh;q=0.9,en;q=0.7'},
        )

    async def search(self, query, count=5, recency_days=None):
        count=max(1,min(int(count),5))
        query=query.strip()
        if not query: raise WebSearchError('INVALID_ARGUMENT','搜索词不能为空')
        effective=query
        if recency_days:
            days=max(1,min(int(recency_days),3650))
            effective+=f' after:{(datetime.now(timezone.utc)-timedelta(days=days)).date().isoformat()}'
        errors=[]
        for provider in self._provider_order():
            try:
                results=await (self._bing(effective,count) if provider=='bing' else self._duckduckgo(effective,count))
                if results:
                    results=[dict(item,title=item['title'][:300],snippet=item['snippet'][:700]) for item in results]
                    return {
                        'query':query,
                        'effective_query':effective,
                        'provider':provider,
                        'searched_at':datetime.now(timezone.utc).isoformat(),
                        'results':results[:count],
                        'verified':True,
                    }
                errors.append(provider+': no results')
            except Exception as exc:
                errors.append(provider+f': {type(exc).__name__}: '+str(exc)[:140])
        raise WebSearchError('NETWORK_ERROR','搜索服务暂时不可用：'+'；'.join(errors))

    def _provider_order(self):
        preferred=os.getenv('ARK_SEARCH_PROVIDER','bing').lower()
        return ['duckduckgo','bing'] if preferred=='duckduckgo' else ['bing','duckduckgo']

    async def _bing(self, query, count):
        response=await self.client.get(
            'https://www.bing.com/search',
            params={'q':query,'format':'rss','count':str(count),'setlang':'zh-Hans'},
            follow_redirects=True,
        )
        if not (response.url.host=='bing.com' or response.url.host.endswith('.bing.com')):
            raise WebSearchError('NETWORK_ERROR','Bing 重定向到了非预期站点')
        response.raise_for_status()
        if len(response.content)>1_048_576: raise WebSearchError('RESPONSE_TOO_LARGE','搜索响应超过 1MB 上限')
        root=ET.fromstring(response.content)
        results=[]
        for item in root.findall('.//item'):
            url=_safe_result_url(item.findtext('link','').strip())
            if not url: continue
            published=None
            raw_date=item.findtext('pubDate')
            if raw_date:
                try: published=parsedate_to_datetime(raw_date).astimezone(timezone.utc).isoformat()
                except Exception: pass
            results.append({
                'title':_clean(item.findtext('title',''))[:500],
                'url':url,
                'snippet':_clean(item.findtext('description',''))[:1200],
                'published_at':published,
            })
        return results[:count]

    async def _duckduckgo(self, query, count):
        response=await self.client.post(
            'https://html.duckduckgo.com/html/',
            data={'q':query},
            headers={'User-Agent':self.user_agent},
            follow_redirects=True,
        )
        if not (response.url.host=='duckduckgo.com' or response.url.host.endswith('.duckduckgo.com')):
            raise WebSearchError('NETWORK_ERROR','DuckDuckGo 重定向到了非预期站点')
        response.raise_for_status()
        if len(response.content)>1_048_576: raise WebSearchError('RESPONSE_TOO_LARGE','搜索响应超过 1MB 上限')
        parser=_DuckDuckGoParser();parser.feed(response.text)
        return parser.results[:count]

    async def fetch_page(self, url, max_chars=7000):
        max_chars=max(1000,min(int(max_chars),9000))
        current=url
        for _ in range(4):
            await self._ensure_public(current)
            async with self.client.stream('GET',current,headers={'Accept':'text/html,text/plain,application/xhtml+xml,application/json;q=0.8'}) as response:
                if response.status_code in {301,302,303,307,308}:
                    location=response.headers.get('location')
                    if not location: raise WebSearchError('NETWORK_ERROR','网页重定向缺少目标地址')
                    current=urljoin(current,location)
                    continue
                response.raise_for_status()
                content_type=response.headers.get('content-type','').split(';')[0].lower()
                allowed=('text/','application/xhtml+xml','application/json')
                if not any(content_type.startswith(item) for item in allowed):
                    raise WebSearchError('UNSUPPORTED_CONTENT',f"暂不支持读取 {content_type or '未知'} 内容")
                declared=response.headers.get('content-length')
                if declared and int(declared)>1_048_576:
                    raise WebSearchError('RESPONSE_TOO_LARGE','网页超过 1MB 读取上限')
                chunks=[];size=0
                async for chunk in response.aiter_bytes():
                    size+=len(chunk)
                    if size>1_048_576: raise WebSearchError('RESPONSE_TOO_LARGE','网页超过 1MB 读取上限')
                    chunks.append(chunk)
                raw=b''.join(chunks)
                encoding=response.charset_encoding or 'utf-8'
                decoded=raw.decode(encoding,errors='replace')
                if 'html' in content_type or '<html' in decoded[:500].lower():
                    parser=_PageTextParser();parser.feed(decoded);title,text=parser.output()
                else:
                    title='';text=_clean(decoded)
                if not text: raise WebSearchError('EMPTY_CONTENT','网页没有可读取的正文')
                return {
                    'url':url,
                    'final_url':str(response.url),
                    'title':title[:500],
                    'content':text[:max_chars],
                    'content_type':content_type,
                    'fetched_at':datetime.now(timezone.utc).isoformat(),
                    'truncated':len(text)>max_chars,
                    'verified':True,
                }
        raise WebSearchError('NETWORK_ERROR','网页重定向次数过多')

    async def _ensure_public(self, value):
        safe=_safe_result_url(value)
        if not safe: raise WebSearchError('INVALID_ARGUMENT','只允许访问公开 HTTP/HTTPS 网页')
        host=urlparse(safe).hostname
        try:
            addresses=await asyncio.to_thread(socket.getaddrinfo,host,None,type=socket.SOCK_STREAM)
        except OSError as exc:
            raise WebSearchError('NETWORK_ERROR',f'无法解析网页域名：{exc}') from exc
        if not addresses: raise WebSearchError('NETWORK_ERROR','网页域名没有可用地址')
        for entry in addresses:
            address=ipaddress.ip_address(entry[4][0].split('%')[0])
            if not address.is_global:
                raise WebSearchError('PERMISSION_DENIED','拒绝访问本机、内网或保留地址')
