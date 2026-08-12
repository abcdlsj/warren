# Host 是资源权威

Host 持有 Project、Workspace 和 Terminal Session 的真实状态与生命周期；Client 只通过连接观察或请求控制。这样 Attachment、网络连接或 Client 进程结束时，Terminal Session 仍可继续存在。

