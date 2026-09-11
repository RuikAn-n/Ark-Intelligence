"""A single-model, side-effect-free Ollama tool-calling probe."""
import json
import os
import time
import ollama

started = time.monotonic()
client = ollama.Client(timeout=120)
response = client.chat(
    model=os.getenv('ARK_MAIN_MODEL', 'qwen3.5:9b-mlx'),
    messages=[{'role':'user','content':'请调用 probe_echo 工具，text 参数为 ark-test。不要直接回答。'}],
    tools=[{'type':'function','function':{'name':'probe_echo','description':'无副作用的测试回声','parameters':{'type':'object','properties':{'text':{'type':'string'}},'required':['text']}}}],
    think=False, options={'num_ctx':8192,'num_predict':256,'temperature':0}, keep_alive='2m',
)
calls = [c.model_dump() for c in (response.message.tool_calls or [])]
ok = bool(calls) and calls[0]['function']['name'] == 'probe_echo' and calls[0]['function']['arguments'] == {'text':'ark-test'}
print(json.dumps({'passed':ok,'elapsed_seconds':round(time.monotonic()-started,2),'calls':calls},ensure_ascii=False))
raise SystemExit(0 if ok else 1)
