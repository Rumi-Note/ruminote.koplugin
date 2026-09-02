--[[
Ruminate 书摘 — 跨端一致的幂等指纹算法（Lua / KOReader 插件端）

必须与云函数 JS 版（cloudfunctions/common/fingerprint.js）产出完全一致的结果。
详见 docs/SCHEMA.md「幂等指纹算法」。

规则：
  分隔符 US = "\31" (0x1F, Unit Separator)
  book_id      = hex(sha256(user_id .. US .. title .. US .. author)):sub(1,24)
  highlight_id = hex(sha256(book_id .. US .. chapter .. US .. text .. US .. pos0 .. US .. pos1))
  空字段用 "" 参与拼接，不能省略字段位置。

基准对照（SCHEMA.md 已钉，Lua 端必须复现）：
  user_id="u_abc123" title="沉思录" author="马可·奥勒留"
  chapter="卷八" text="如果你为某个外在的事物所困扰，那困扰你的其实不是那件事本身。"
  pos0="/body/div[1]/p[12]/text().0" pos1="/body/div[1]/p[12]/text().45"
  => book_id      = 98542353b772e1fe16b399a1
  => highlight_id = b91c06defc640ea3a08fb421851a94a346ce7260f714aa70dfb4713586b7c9f4

KOReader 自带 sha2 库（rapidjson/sha2），优先用它；否则回退到本文件内置的纯 Lua sha256。
--]]

local US = string.char(31) -- Unit Separator \x1f

-- 优先用 KOReader/luajit 环境里的 sha2（若可用）
local function try_require_sha256()
    local ok, sha2 = pcall(require, "ffi/sha2")
    if ok and sha2 and sha2.sha256 then
        return function(s) return sha2.sha256(s) end
    end
    -- 备用：luajit 常见的 sha2 模块
    local ok2, sha2b = pcall(require, "sha2")
    if ok2 and sha2b and sha2b.sha256 then
        return function(s) return sha2b.sha256(s) end
    end
    return nil
end

-- ---- 纯 Lua SHA-256 回退实现（无外部依赖，供无 sha2 库的环境使用）----
-- 参考标准 FIPS 180-4；仅用于指纹，不追求高性能。
local function pure_sha256(msg)
    local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
    local rshift, lshift = bit.rshift, bit.lshift

    local function rrotate(x, n)
        return bor(rshift(x, n), lshift(x, 32 - n))
    end

    local K = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
    }

    local h0,h1,h2,h3 = 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a
    local h4,h5,h6,h7 = 0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19

    local len = #msg
    local bitlen = len * 8
    msg = msg .. string.char(0x80)
    while (#msg % 64) ~= 56 do msg = msg .. string.char(0) end
    -- 64-bit big-endian length（Lua number 精度足够我们的短输入；高 32 位补 0）
    local hi = math.floor(bitlen / 0x100000000)
    local lo = bitlen % 0x100000000
    local function u32be(n)
        return string.char(
            band(rshift(n,24),0xff), band(rshift(n,16),0xff),
            band(rshift(n,8),0xff), band(n,0xff))
    end
    msg = msg .. u32be(hi) .. u32be(lo)

    for chunk = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            local b1,b2,b3,b4 = msg:byte(chunk + i*4, chunk + i*4 + 3)
            w[i] = bor(lshift(b1,24), lshift(b2,16), lshift(b3,8), b4)
        end
        for i = 16, 63 do
            local s0 = bxor(rrotate(w[i-15],7), rrotate(w[i-15],18), rshift(w[i-15],3))
            local s1 = bxor(rrotate(w[i-2],17), rrotate(w[i-2],19), rshift(w[i-2],10))
            w[i] = band(w[i-16] + s0 + w[i-7] + s1, 0xffffffff)
        end

        local a,b,c,d,e,f,g,h = h0,h1,h2,h3,h4,h5,h6,h7
        for i = 0, 63 do
            local S1 = bxor(rrotate(e,6), rrotate(e,11), rrotate(e,25))
            local ch = bxor(band(e,f), band(bnot(e),g))
            local temp1 = band(h + S1 + ch + K[i+1] + w[i], 0xffffffff)
            local S0 = bxor(rrotate(a,2), rrotate(a,13), rrotate(a,22))
            local maj = bxor(band(a,b), band(a,c), band(b,c))
            local temp2 = band(S0 + maj, 0xffffffff)
            h=g; g=f; f=e; e=band(d+temp1,0xffffffff); d=c; c=b; b=a; a=band(temp1+temp2,0xffffffff)
        end

        h0=band(h0+a,0xffffffff); h1=band(h1+b,0xffffffff); h2=band(h2+c,0xffffffff); h3=band(h3+d,0xffffffff)
        h4=band(h4+e,0xffffffff); h5=band(h5+f,0xffffffff); h6=band(h6+g,0xffffffff); h7=band(h7+h,0xffffffff)
    end

    -- luajit 的 bit 运算返回有符号 32 位整数，直接 %08x 遇负数会输出 16 位。
    -- 先用 %08x 配合 band(x,0xffffffff) 归一：LuaJIT 中 tobit 后需转无符号再格式化。
    local function u32hex(n)
        -- 将有符号 32 位转成 [0, 2^32) 的 Lua number 再格式化
        if n < 0 then n = n + 0x100000000 end
        return string.format("%08x", n)
    end
    return u32hex(h0)..u32hex(h1)..u32hex(h2)..u32hex(h3)..u32hex(h4)..u32hex(h5)..u32hex(h6)..u32hex(h7)
end

local sha256 = try_require_sha256() or pure_sha256

local M = { US = US }

function M.sha256hex(s)
    return sha256(s)
end

--- 计算 book_id（同用户同书唯一），取 sha256 前 24 位十六进制
function M.compute_book_id(user_id, title, author)
    local s = table.concat({ user_id or "", title or "", author or "" }, US)
    return M.sha256hex(s):sub(1, 24)
end

--- 计算 highlight_id（内容指纹，幂等主键）
function M.compute_highlight_id(book_id, chapter, text, pos0, pos1)
    local s = table.concat({ book_id or "", chapter or "", text or "", pos0 or "", pos1 or "" }, US)
    return M.sha256hex(s)
end

return M
