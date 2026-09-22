"""Allowlisted Python Skill handlers with bounded concurrency."""
import asyncio

from skills.registry import SkillError
from tools.web_search import WebSearchClient, WebSearchError
from tools.workspace import WorkspaceExecutor


class PythonExecutor:
    def __init__(self, web=None, max_network_concurrency=2, workspace=None):
        self.web=web
        self.workspace=workspace or WorkspaceExecutor()
        self.network_slots=asyncio.Semaphore(max(1,min(max_network_concurrency,2)))

    async def execute(self, handler, arguments):
        if handler == 'notifications.query':
            from runtime.notification_events import EventStore, EventRange
            from runtime.security import runtime_dir
            return await asyncio.to_thread(EventStore(runtime_dir() / 'notifications.sqlite3').query, EventRange(**arguments))
        if handler.startswith('workspace.'):
            return await self.workspace.execute(handler,arguments)
        if handler=='example.echo':
            return {'text':arguments['text'],'verified':True}
        try:
            if handler=='web.search':
                async with self.network_slots:
                    return await self._web().search(
                        arguments['query'],
                        count=arguments.get('count',5),
                        recency_days=arguments.get('recency_days'),
                    )
            if handler=='web.fetch_page':
                async with self.network_slots:
                    return await self._web().fetch_page(
                        arguments['url'],max_chars=arguments.get('max_chars',7000),
                    )
        except WebSearchError as exc:
            raise SkillError(exc.code,str(exc)) from exc
        raise SkillError('CAPABILITY_UNAVAILABLE','Python handler 尚未注册')

    def _web(self):
        if self.web is None: self.web=WebSearchClient()
        return self.web

    async def prepare(self, handler, arguments):
        if handler.startswith('workspace.'):
            return await asyncio.to_thread(self.workspace.prepare,handler,arguments)
        return {'arguments':arguments}
