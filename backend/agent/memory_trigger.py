class MemoryTrigger:
    #basic version:基于关键词触发记忆储存
    KEYWORDS = [
        "我叫",
        "我是",
        "我的",
        "我喜欢",
        "我习惯",
        "我正在",
        "我计划",
        "我的项目",
        "以后",
        "长期",
        "目标",
        "正在开发",
    ]

    @classmethod
    def should_check(cls, message):

        return any(
            keyword in message
            for keyword in cls.KEYWORDS
        )