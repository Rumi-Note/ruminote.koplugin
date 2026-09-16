--[[
Ruminote 如觅书摘 — KOReader 插件主体

职责：
  1. 在阅读界面菜单加入 "Ruminote 如觅书摘"（绑定账号 / 立即同步 / 查看队列 / 关于）
  2. 用户新增高亮时，把书摘写入本地上传队列（离线优先）
  3. 联网时把队列批量 POST 到 CloudBase 的 ruminateapi（幂等，后端去重）
  4. 6 位配对码绑定，换取长期 device_token 持久化到插件设置

设计要点（见 docs/PLAN.md 风险登记）：
  - e-ink 设备 Wi-Fi 间歇：不做实时，改离线队列 + 手动/联网批量上传
  - 幂等：每条书摘的 highlight_id 由 fingerprint.lua 计算，与云端 JS 一致
  - KOReader 版本碎片：锁定较新稳定版（annotations 表），旧版 highlights 兼容留 TODO
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local fingerprint = require("fingerprint")

-- ============ 配置 ============
-- CloudBase HTTP 网关基地址（企业号新环境 cloud1-d7g8j2h4675ed447b）。末尾不要带斜杠。
-- HTTP 网关路由：/ruminateapi -> 云函数 ruminateapi（路径透传开启，身份认证关闭）。
-- 云函数用 path.endsWith 匹配，故带 /ruminateapi 前缀的完整路径也能命中。
local DEFAULT_API_BASE = "https://cloud1-d7g8j2h4675ed447b-1480876426.ap-shanghai.app.tcloudbase.com/ruminateapi"

local Ruminate = WidgetContainer:extend{
    name = "ruminate",
}

-- ============ 设置与队列的本地存储 ============
local function settings_file()
    return DataStorage:getSettingsDir() .. "/ruminate.lua"
end

function Ruminate:_loadSettings()
    self.settings = LuaSettings:open(settings_file())
    self.api_base = self.settings:readSetting("api_base") or DEFAULT_API_BASE
    self.device_token = self.settings:readSetting("device_token") -- 可能为 nil（未绑定）
    self.queue = self.settings:readSetting("queue") or {}          -- 待上传书摘数组
    self.synced = self.settings:readSetting("synced") or {}        -- 已成功同步的 hid 集合 { [hid]=true }（增量同步用）

    -- device_id：本设备唯一标识，首次生成后持久化，永不变。
    -- 云端 devices 集合以 device_id 为主键做全局唯一归属；重装插件若沿用同一 device_id
    -- 可在原账号幂等重绑，换账号则需先在原账号小程序解绑。ko_ 前缀标识终端类型。
    self.device_id = self.settings:readSetting("device_id")
    if not self.device_id then
        self.device_id = self:_genDeviceId()
        self.settings:saveSetting("device_id", self.device_id)
        self.settings:flush()
    end
end

-- 生成唯一 device_id：ko_ + 时间戳 + 随机十六进制。无需真实设备指纹（隐私/稳定性）。
function Ruminate:_genDeviceId()
    math.randomseed(os.time() + os.clock() * 1000000)
    local rnd = ""
    for _ = 1, 16 do rnd = rnd .. string.format("%x", math.random(0, 15)) end
    return "ko_" .. tostring(os.time()) .. "_" .. rnd
end

-- 设备显示名（小程序设备列表可读）。KOReader 提供的设备型号信息有限，给个可辨识的默认名。
function Ruminate:_deviceName()
    local model
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.model then model = Device.model end
    return "KOReader" .. (model and (" · " .. tostring(model)) or "")
end

function Ruminate:_saveQueue()
    self.settings:saveSetting("queue", self.queue)
    self.settings:flush()
end

function Ruminate:_saveSynced()
    self.settings:saveSetting("synced", self.synced)
    self.settings:flush()
end

function Ruminate:_saveToken(token)
    self.device_token = token
    self.settings:saveSetting("device_token", token)
    self.settings:flush()
end

-- ============ 生命周期 ============
function Ruminate:init()
    self:_loadSettings()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    -- 启动周期自动同步（插件运行期间每 10 分钟静默尝试一次）
    self:_scheduleAutoSync()
end

-- ============ 自动同步组合 ============
-- 触发时机：① 周期定时(10min) ② 关书 ③ 挂起/唤醒 ④ 菜单手动(兜底)。
-- 联网检测：tryFlush 内部已判 NetworkMgr:isOnline()，离线则只留队列不报错。
-- 全部走 interactive=false（静默），不打扰阅读；手动「立即同步」才有提示。
local AUTO_SYNC_INTERVAL = 10 * 60 -- 秒

function Ruminate:_scheduleAutoSync()
    self:_cancelAutoSync()
    self._autoSyncScheduled = true
    self._autoSyncFn = function()
        if not self._autoSyncScheduled then return end
        -- 扫描当前书新增标注入队，再静默尝试上传
        pcall(function() self:_enqueueLatestAnnotations() end)
        pcall(function() self:tryFlush(false) end)
        -- 重新排下一次（循环）
        self:_scheduleAutoSync()
    end
    UIManager:scheduleIn(AUTO_SYNC_INTERVAL, self._autoSyncFn)
end

function Ruminate:_cancelAutoSync()
    self._autoSyncScheduled = false
    if self._autoSyncFn and UIManager.unschedule then
        UIManager:unschedule(self._autoSyncFn)
        self._autoSyncFn = nil
    end
end

-- 静默同步：扫描当前书 + 尝试上传（不打扰）
function Ruminate:_autoSyncNow()
    pcall(function() self:_enqueueLatestAnnotations() end)
    pcall(function() self:tryFlush(false) end)
end

-- 关书：把当前书的标注收尾同步
function Ruminate:onCloseDocument()
    self:_autoSyncNow()
end

-- 设备挂起（息屏/合盖）前：抓紧同步一次
function Ruminate:onSuspend()
    self:_autoSyncNow()
end

-- 唤醒后：网络可能恢复，补一次
function Ruminate:onResume()
    self:_autoSyncNow()
end

-- 插件卸载/退出：停掉定时器，避免泄漏
function Ruminate:onClose()
    self:_cancelAutoSync()
end

-- 注册到 KOReader 主菜单（工具 → Ruminote 如觅书摘）
function Ruminate:addToMainMenu(menu_items)
    menu_items.ruminate = {
        text = _("Ruminote 如觅书摘"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("立即同步"),
                keep_menu_open = true,
                callback = function()
                    -- 先扫描当前书的所有高亮入队，再上传（不依赖高亮事件钩子）
                    local n = self:_enqueueLatestAnnotations()
                    self:tryFlush(true)
                end,
            },
            {
                text = _("扫描本书书摘"),
                keep_menu_open = true,
                callback = function()
                    local n = self:_enqueueLatestAnnotations()
                    UIManager:show(InfoMessage:new{
                        text = T(_("已扫描并入队 %1 条新书摘。\n当前待上传 %2 条。"), n, #self.queue),
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("待上传书摘：%1 条"), #self.queue)
                end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("当前队列有 %1 条书摘等待上传。\n联网后点“立即同步”即可上传。"), #self.queue),
                    })
                end,
            },
            {
                text_func = function()
                    return self.device_token and _("重新绑定账号") or _("绑定账号（输入配对码）")
                end,
                keep_menu_open = true,
                callback = function() self:_showBindDialog() end,
            },
            {
                text = _("关于 Ruminote 如觅书摘"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("Ruminote 如觅书摘\n好句子，值得再嚼一遍。\n\n划线自动收进云端，随时回看。"),
                    })
                end,
            },
        },
    }
end

-- ============ 高亮事件：入队 ============
-- KOReader 在保存高亮/笔记后会广播事件。不同版本事件名有差异，
-- 这里挂较通用的 onSaveHighlight；若你的版本用别的钩子，可在 README 里改。
-- 触发到时：入队 + 联网则静默即传（"划线即传"，失败不打扰，留队列）。
function Ruminate:onSaveHighlight()
    self:_enqueueLatestAnnotations()
    pcall(function() self:tryFlush(false) end)
end

-- 从当前文档的 annotations 表提取尚未入队的高亮，加入队列。
-- 返回本次新增条数。兼容多版本 KOReader 的不同存储位置。
function Ruminate:_enqueueLatestAnnotations()
    local annotations = self:_collectAnnotations()
    if not annotations or #annotations == 0 then
        logger.warn("[ruminate] no annotations found")
        return 0
    end

    local book = self:_bookMeta()
    local added = 0
    for _, a in ipairs(annotations) do
        local text = a.text or a.notes or a.highlighted_text
        if text and text ~= "" then
            local pos0 = tostring(a.pos0 or a.page or a.pageno or "")
            local pos1 = tostring(a.pos1 or "")
            local chapter = a.chapter or ""
            local hid = fingerprint.compute_highlight_id(
                fingerprint.compute_book_id("", book.title, book.author),
                chapter, text, pos0, pos1)
            -- 增量：已成功同步过(synced)或已在队列的，都不再入队
            if not self.synced[hid] and not self:_inQueue(hid) then
                table.insert(self.queue, {
                    _local_id = hid,
                    book = book,
                    text = text,
                    note = a.note or "",
                    chapter = chapter,
                    pos0 = pos0, pos1 = pos1,
                    color = a.color or "",
                    koreader_ts = os.time(),
                })
                added = added + 1
            end
        end
    end
    if added > 0 then self:_saveQueue() end
    return added
end

-- 探测当前文档的高亮/标注表，兼容 KOReader 多版本存储位置
function Ruminate:_collectAnnotations()
    -- 1) 新版：ui.annotation.annotations（数组）
    if self.ui and self.ui.annotation and type(self.ui.annotation.annotations) == "table" then
        if #self.ui.annotation.annotations > 0 then
            return self.ui.annotation.annotations
        end
    end
    -- 2) 旧版：ui.highlight.highlights（按页 { [page] = { {...}, ... } }）
    if self.ui and self.ui.highlight and type(self.ui.highlight.highlights) == "table" then
        local flat = {}
        for _, page_list in pairs(self.ui.highlight.highlights) do
            if type(page_list) == "table" then
                for _, h in ipairs(page_list) do table.insert(flat, h) end
            end
        end
        if #flat > 0 then return flat end
    end
    -- 3) 从 DocSettings 读 annotations / highlight
    local ok, ds = pcall(function()
        return self.ui and self.ui.doc_settings
    end)
    if ok and ds then
        local ann = ds:readSetting("annotations")
        if type(ann) == "table" and #ann > 0 then return ann end
        local hl = ds:readSetting("highlight")
        if type(hl) == "table" then
            local flat = {}
            for _, page_list in pairs(hl) do
                if type(page_list) == "table" then
                    for _, h in ipairs(page_list) do table.insert(flat, h) end
                end
            end
            if #flat > 0 then return flat end
        end
    end
    return nil
end

function Ruminate:_inQueue(local_id)
    for _, item in ipairs(self.queue) do
        if item._local_id == local_id then return true end
    end
    return false
end

-- 从文件路径提取去扩展名的文件名，作为书名兜底
-- （元数据 title 有时读不到，用文件名可保证同一本书 book_id 稳定，不会重复入库）
function Ruminate:_fileNameTitle()
    local path = self.ui and self.ui.document and self.ui.document.file
    if not path or path == "" then return nil end
    local name = path:match("([^/\\]+)$") or path   -- 去目录
    name = name:gsub("%.[^.]+$", "")                 -- 去扩展名
    name = name:gsub("^%s+", ""):gsub("%s+$", "")    -- trim
    if name == "" then return nil end
    return name
end

function Ruminate:_bookMeta()
    local title, author = nil, ""
    if self.ui and self.ui.document then
        local props = self.ui.document:getProps() or {}
        if props.title and props.title ~= "" then
            title = props.title
        end
        author = props.authors or props.author or ""
    end
    -- 元数据无标题时用文件名兜底，最后才退回“未知书籍”；
    -- 关键：同一本书任何时候都算出同一个 title -> 同一个 book_id，避免重复。
    title = title or self:_fileNameTitle() or _("未知书籍")
    return { title = title, author = author }
end

-- ============ 上传 ============
-- interactive=true 时给出提示（用户点“立即同步”）；false 为后台静默
function Ruminate:tryFlush(interactive)
    if not self.device_token then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("尚未绑定账号，请先在菜单里输入配对码绑定。") })
        end
        return
    end
    if #self.queue == 0 then
        if interactive then
            UIManager:show(InfoMessage:new{ text = _("没有待上传的书摘。") })
        end
        return
    end
    if not NetworkMgr:isOnline() then
        if interactive then
            NetworkMgr:promptWifiOn() -- 提示用户开 Wi-Fi
        end
        return
    end

    -- 组装 batch payload（去掉本地字段 _local_id）
    local items = {}
    for _, q in ipairs(self.queue) do
        table.insert(items, {
            book = q.book, text = q.text, note = q.note,
            chapter = q.chapter, pos0 = q.pos0, pos1 = q.pos1,
            color = q.color, koreader_ts = q.koreader_ts,
        })
    end

    local ok, resp = self:_postBatch(items)
    if ok then
        local n = #self.queue
        local quotaHit = type(resp) == "table" and resp.quota_exceeded
        if not quotaHit then
            -- 整批成功（云端已入库或 duplicated）→ 记入已同步集，实现增量：以后不再重传这些。
            for _, q in ipairs(self.queue) do
                if q._local_id then self.synced[q._local_id] = true end
            end
            self:_saveSynced()
        end
        -- quota_exceeded 时整批不记 synced：下次全量扫描会重新入队重传，靠云端 hid 幂等去重（数据量小，可接受）。
        self.queue = {}
        self:_saveQueue()
        if quotaHit then
            -- 额度用完：已扣额度的部分入库，超额部分未上传。额度提示对用户重要，静默模式下也弹。
            UIManager:show(InfoMessage:new{
                text = resp.message or _("创建书摘次数已用完，请在 Ruminote 小程序购买使用次数后再同步。"),
                timeout = 8,
            })
        elseif interactive then
            local acc = (type(resp) == "table" and resp.accepted) or n
            UIManager:show(InfoMessage:new{ text = T(_("已同步 %1 条书摘到 Ruminote。"), acc) })
        end
    else
        if interactive then
            UIManager:show(InfoMessage:new{ text = T(_("同步失败：%1\n书摘已保留，稍后重试。"), tostring(resp)) })
        end
    end
end

-- POST /highlights/batch，带 X-Device-Token。返回 ok(bool), 结果/错误信息
function Ruminate:_postBatch(items)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")

    local body = json.encode({ items = items })
    local respbody = {}
    local url = self.api_base .. "/highlights/batch"
    local ok, code = pcall(function()
        local _, c = http.request{
            url = url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
                ["X-Device-Token"] = self.device_token,
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(respbody),
        }
        return c
    end)
    if not ok then return false, "网络错误" end
    if code == 401 then
        return false, "device_token 失效，请重新绑定"
    end
    if code ~= 200 then
        return false, "HTTP " .. tostring(code)
    end
    local json = require("json")
    local parsed = json.decode(table.concat(respbody)) or {}
    return true, parsed
end

-- ============ 绑定 ============
function Ruminate:_showBindDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("绑定 Ruminote 账号"),
        input_hint = _("在小程序里生成 6 位配对码"),
        input_type = "number",
        buttons = {{
            { text = _("取消"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("绑定"), is_enter_default = true, callback = function()
                local code = dialog:getInputText()
                UIManager:close(dialog)
                self:_bind(code)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ruminate:_bind(pair_code)
    if not pair_code or pair_code == "" then return end
    if not NetworkMgr:isOnline() then
        NetworkMgr:promptWifiOn()
        return
    end
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")

    local body = json.encode({
        pair_code = pair_code,
        device_id = self.device_id,
        device_name = self:_deviceName(),
        platform = "koreader",
    })
    local respbody = {}
    local url = self.api_base .. "/device/bind"
    local ok, code = pcall(function()
        local _, c = http.request{
            url = url, method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(respbody),
        }
        return c
    end)
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("绑定失败，请检查网络连接。") })
        return
    end
    -- 无论状态码都尝试解析响应体，以便读出业务错误码（如设备已绑其他账号）
    local resp = json.decode(table.concat(respbody)) or {}
    if code ~= 200 then
        if resp.code == "DEVICE_BOUND_ELSEWHERE" then
            UIManager:show(InfoMessage:new{
                text = _("这台设备已绑定到其他账号。\n请先在原账号的 Ruminote 小程序「我的 → 我的设备」里解除这台设备的绑定，再重新绑定。"),
                timeout = 8,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("绑定失败：%1"), resp.message or _("请检查配对码或网络")),
            })
        end
        return
    end
    if resp and resp.ok and resp.device_token then
        self:_saveToken(resp.device_token)
        UIManager:show(InfoMessage:new{ text = _("绑定成功！以后划线会自动同步到 Ruminote。") })
        self:tryFlush(false)
    else
        UIManager:show(InfoMessage:new{ text = _("配对码无效或已过期，请重新生成。") })
    end
end

return Ruminate
