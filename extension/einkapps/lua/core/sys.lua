-- Low-level system helpers (LuaJIT FFI). Works on the Kindle (32-bit ARM,
-- glibc) and on a desktop Linux box for the simulator.
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
struct ea_timeval { long tv_sec; long tv_usec; };
int gettimeofday(struct ea_timeval *tv, void *tz);
int open(const char *pathname, int flags, ...);
int close(int fd);
long read(int fd, void *buf, size_t count);
long write(int fd, const void *buf, size_t count);
int ioctl(int fd, unsigned long request, ...);
struct ea_pollfd { int fd; short events; short revents; };
int poll(struct ea_pollfd *fds, unsigned long nfds, int timeout);
int usleep(unsigned int usec);
typedef struct _IO_FILE FILE;
FILE *popen(const char *command, const char *type);
int pclose(FILE *stream);
int fileno(FILE *stream);
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int fflush(FILE *stream);
int memcmp(const void *s1, const void *s2, size_t n);
int fcntl(int fd, int cmd, ...);
char *strerror(int errnum);
]]

local C = ffi.C
local sys = {}

sys.O_RDONLY = 0
sys.O_NONBLOCK = 0x800
sys.POLLIN = 1
sys.F_GETFL = 3
sys.F_SETFL = 4

local tv = ffi.new("struct ea_timeval")

-- Milliseconds since the epoch (wall clock).
function sys.now()
    C.gettimeofday(tv, nil)
    return tonumber(tv.tv_sec) * 1000 + math.floor(tonumber(tv.tv_usec) / 1000)
end

function sys.sleep_ms(ms)
    if ms > 0 then C.usleep(ms * 1000) end
end

function sys.errno_str()
    return ffi.string(C.strerror(ffi.errno()))
end

function sys.file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function sys.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function sys.write_file(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    f:write(data)
    f:close()
    os.rename(tmp, path)
    return true
end

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
sys.quote = shell_quote

function sys.mkdir_p(path)
    os.execute("mkdir -p " .. shell_quote(path) .. " 2>/dev/null")
end

-- Run a command and return its stdout (trimmed of one trailing newline).
function sys.capture(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil end
    local out = p:read("*a")
    p:close()
    if out then out = out:gsub("\n$", "") end
    return out
end

function sys.list_dir(path)
    local out = {}
    local p = io.popen("ls -1 " .. shell_quote(path) .. " 2>/dev/null")
    if not p then return out end
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

-- A child process whose stdout we can poll without blocking.
-- Used for `lipc-wait-event` so power-button events reach the main loop.
local Reader = {}
Reader.__index = Reader

function sys.spawn_reader(cmd)
    local fp = C.popen(cmd, "r")
    if fp == nil then return nil end
    local fd = C.fileno(fp)
    local fl = C.fcntl(fd, sys.F_GETFL)
    C.fcntl(fd, sys.F_SETFL, ffi.cast("int", bit.bor(fl, sys.O_NONBLOCK)))
    return setmetatable({ fp = fp, fd = fd, buf = "", bufc = ffi.new("char[4096]") }, Reader)
end

-- Returns a list of complete lines read so far (possibly empty).
function Reader:read_lines()
    local lines = {}
    if not self.fp then return lines end
    while true do
        local n = tonumber(C.read(self.fd, self.bufc, 4096))
        if n and n > 0 then
            self.buf = self.buf .. ffi.string(self.bufc, n)
        else
            if n == 0 then self:close() end
            break
        end
    end
    while true do
        local i = self.buf:find("\n", 1, true)
        if not i then break end
        lines[#lines + 1] = self.buf:sub(1, i - 1)
        self.buf = self.buf:sub(i + 1)
    end
    return lines
end

function Reader:close()
    if self.fp then
        -- pclose would block waiting for a long-running child; just drop it.
        self.fp = nil
    end
end

-- Write raw bytes to a command's stdin (binary-safe, used for fbink).
function sys.pipe_write(cmd, ptr, len)
    local fp = C.popen(cmd, "w")
    if fp == nil then return false end
    C.fwrite(ptr, 1, len, fp)
    return C.pclose(fp) == 0
end

-- Poll a list of fds. Returns a set {fd=true} of readable fds.
function sys.poll(fds, timeout_ms)
    local n = #fds
    local ready = {}
    if n == 0 then
        sys.sleep_ms(timeout_ms)
        return ready
    end
    local pfds = ffi.new("struct ea_pollfd[?]", n)
    for i = 1, n do
        pfds[i - 1].fd = fds[i]
        pfds[i - 1].events = sys.POLLIN
    end
    local r = C.poll(pfds, n, timeout_ms)
    if r > 0 then
        for i = 1, n do
            if pfds[i - 1].revents ~= 0 then ready[fds[i]] = true end
        end
    end
    return ready
end

-- UTF-8 helpers -------------------------------------------------------------

-- Iterate codepoints: for pos, cp in sys.utf8_codes(s) do ... end
function sys.utf8_codes(s)
    local i, n = 1, #s
    return function()
        if i > n then return nil end
        local start = i
        local c = s:byte(i)
        local cp, len
        if c < 0x80 then cp, len = c, 1
        elseif c >= 0xF0 then
            local c2, c3, c4 = s:byte(i + 1, i + 3)
            if c4 then cp = bit.bor(bit.lshift(bit.band(c, 7), 18), bit.lshift(bit.band(c2, 0x3F), 12), bit.lshift(bit.band(c3, 0x3F), 6), bit.band(c4, 0x3F)) else cp = 0xFFFD end
            len = 4
        elseif c >= 0xE0 then
            local c2, c3 = s:byte(i + 1, i + 2)
            if c3 then cp = bit.bor(bit.lshift(bit.band(c, 0x0F), 12), bit.lshift(bit.band(c2, 0x3F), 6), bit.band(c3, 0x3F)) else cp = 0xFFFD end
            len = 3
        elseif c >= 0xC0 then
            local c2 = s:byte(i + 1)
            if c2 then cp = bit.bor(bit.lshift(bit.band(c, 0x1F), 6), bit.band(c2, 0x3F)) else cp = 0xFFFD end
            len = 2
        else
            cp, len = 0xFFFD, 1
        end
        i = i + len
        return start, cp
    end
end

function sys.utf8_char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + bit.rshift(cp, 6), 0x80 + bit.band(cp, 0x3F))
    elseif cp < 0x10000 then
        return string.char(0xE0 + bit.rshift(cp, 12), 0x80 + bit.band(bit.rshift(cp, 6), 0x3F), 0x80 + bit.band(cp, 0x3F))
    else
        return string.char(0xF0 + bit.rshift(cp, 18), 0x80 + bit.band(bit.rshift(cp, 12), 0x3F),
            0x80 + bit.band(bit.rshift(cp, 6), 0x3F), 0x80 + bit.band(cp, 0x3F))
    end
end

-- Remove the last UTF-8 character of a string.
function sys.utf8_pop(s)
    local i = #s
    while i > 0 do
        local c = s:byte(i)
        if c < 0x80 or c >= 0xC0 then return s:sub(1, i - 1) end
        i = i - 1
    end
    return ""
end

function sys.utf8_len(s)
    local n = 0
    for _ in sys.utf8_codes(s) do n = n + 1 end
    return n
end

return sys
