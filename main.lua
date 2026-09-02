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
-- CloudBase HTTP 访问服务基地址（见 docs/ENV.md）。末尾不要带斜杠。
-- ⚠️ 阶段二联调前，把 ruminateapi 挂到 HTTP 访问服务后，用真实域名替换此处，
--    路径形如  <base>/ruminateapi/device/bind  或自定义映射的  <base>/device/bind
local DEFAULT_API_BASE = "https://cloud1-d2gao2pxfdeb837d8-1477949046.ap-shanghai.app.tcloudbase.com/ruminateapi"

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
end

function Ruminate:_saveQueue()
    self.settings:saveSetting("queue", self.queue)
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
function Ruminate:onSaveHighlight()
    self:_enqueueLatestAnnotations()
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
            if not self:_inQueue(hid) then
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

function Ruminate:_bookMeta()
    local title, author = _("未知书籍"), ""
    if self.ui and self.ui.document then
        local props = self.ui.document:getProps() or {}
        title = (props.title and props.title ~= "" and props.title) or title
        author = props.authors or props.author or ""
    end
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
        self.queue = {}
        self:_saveQueue()
        if interactive then
            UIManager:show(InfoMessage:new{ text = T(_("已同步 %1 条书摘到 Ruminote。"), n) })
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
    return true, table.concat(respbody)
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

    local body = json.encode({ pair_code = pair_code })
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
    if not ok or code ~= 200 then
        UIManager:show(InfoMessage:new{ text = _("绑定失败，请检查配对码或网络。") })
        return
    end
    local resp = json.decode(table.concat(respbody))
    if resp and resp.ok and resp.device_token then
        self:_saveToken(resp.device_token)
        UIManager:show(InfoMessage:new{ text = _("绑定成功！以后划线会自动同步到 Ruminote。") })
        self:tryFlush(false)
    else
        UIManager:show(InfoMessage:new{ text = _("配对码无效或已过期，请重新生成。") })
    end
end

return Ruminate
