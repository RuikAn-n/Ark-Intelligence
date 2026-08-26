class MemoryTrigger:
    #basic version:基于关键词触发记忆储存
    KEYWORDS = [
        "请记住",
        "记住",
        "别忘了",
        "我的名字是",
        "我叫",
        "我喜欢",
        "我偏好",
        "我习惯",
        "我的项目是",
        "我正在开发",
        "我计划",
        "我的目标是",
        "长期目标",
    ]

    @classmethod
    def should_check(cls, message):

        return any(
            keyword in message
            for keyword in cls.KEYWORDS
        )