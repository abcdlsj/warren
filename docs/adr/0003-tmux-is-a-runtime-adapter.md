# tmux 是可替换的运行时适配器

tmux 只负责把 Host 的终端运行时能力接入系统，不成为 Project、Workspace、Terminal Session 或 Client Layout 的领域对象。这样运行时可以替换，而领域关系和 Client 协议不必随之改变。

