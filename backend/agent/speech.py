"""Shared identity and deterministic spoken-text segmentation (no extra LLM)."""
import re

IDENTITY = '你叫 Sophie，是运行在用户 Mac 上的 Ark Intelligence 个人助手。跟随用户使用中文或英文；除非用户要求翻译，不要无故混用语言。'
VOICE_STYLE = '''当前是语音对话。像面对面聊天一样回答，先回答核心问题，通常一到三个简短口语句，再按需要展开。
不用标题、Markdown、列表编号或朗读网址。不要反复说“好的”，不要刻意添加语气词。
保持事实、数字、日期和工具结果准确。工具失败、未执行、等待审批不能说已完成。
不要暴露推理或工具参数。用户要求详细说明时可以展开，但使用短句和自然停顿。'''


def explicit_memory(message):
    match = re.match(r'^\s*(?:请\s*)?记住\s*[:：,，]?\s*(.+)$', message, re.S)
    if not match:
        match = re.match(r'^\s*(?:please\s+)?remember\s+(?:that\s+)?(.+)$', message, re.I | re.S)
    return match.group(1).strip() if match else None


def spoken_text(text):
    text = re.sub(r'```[\s\S]*?```', '（代码请查看屏幕）', text)
    text = re.sub(r'\[([^\]]+)\]\(https?://[^)]+\)', r'\1', text)
    text = re.sub(r'https?://\S+', '', text)
    text = re.sub(r'(?m)^\s*(?:#{1,6}\s+|[-*]\s+|\d+[.)]\s+)', '', text)
    return text.replace('**', '').replace('`', '').strip()


class SentenceBuffer:
    """Only consume final-answer text. Never split numbers at decimal points."""
    def __init__(self):
        self.pending = ''

    def add(self, text, final=False):
        self.pending += text
        result = []
        while self.pending:
            boundary = next((match for match in re.finditer(r'[。！？!?；;\n]|\.(?=\s)|[,，](?=\s|[^0-9])', self.pending)
                             if match.group() not in ',，' or match.end() >= 28), None)
            if boundary:
                end = boundary.end()
            elif len(self.pending) > 160:
                # Prefer a word boundary; CJK without spaces can be split at this cap.
                end = self.pending.rfind(' ', 40, 160)
                if end < 0:
                    end = 160 if re.search(r'[\u4e00-\u9fff]', self.pending[:160]) else 0
                if not end and not final:
                    break
                if not end:
                    end = len(self.pending)
            elif final:
                end = len(self.pending)
            else:
                break
            raw, self.pending = self.pending[:end], self.pending[end:]
            value = spoken_text(raw)
            if value:
                result.append(value)
        return result
